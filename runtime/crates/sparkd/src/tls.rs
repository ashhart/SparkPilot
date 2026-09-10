//! Keep persistent TLS identity distinct from pairing authority; Apple pins SHA-256 of the exact served leaf DER.

use std::fs::{self, Metadata, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use rustls::pki_types::pem::PemObject as _;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

pub const CERTIFICATE_FILE_NAME: &str = "node.crt";
pub const PRIVATE_KEY_FILE_NAME: &str = "node.key";

const CREATION_LOCK_FILE_NAME: &str = ".tls-identity.lock";
/// Treat untouched creation locks older than five minutes as stale, well beyond normal key/certificate generation time.
const STALE_CREATION_LOCK: std::time::Duration = std::time::Duration::from_secs(300);
const KEY_FILE_MODE: u32 = 0o600;
const CERTIFICATE_FILE_MODE: u32 = 0o644;
const DIRECTORY_MODE: u32 = 0o700;
const MAX_IDENTITY_FILE_BYTES: u64 = 64 * 1024;
const SUBJECT_ALT_NAMES: &[&str] = &["spark.local", "localhost", "spark"];

#[derive(Debug, Error)]
pub enum TlsIdentityError {
    #[error("I/O error at {path}: {reason}")]
    Io { path: PathBuf, reason: String },
    #[error("TLS identity path is a symbolic link: {path}")]
    Symlink { path: PathBuf },
    #[error("TLS identity path is not a regular file: {path}")]
    NotRegularFile { path: PathBuf },
    #[error("TLS identity directory is not a directory: {path}")]
    NotDirectory { path: PathBuf },
    #[error("TLS identity directory {path} has insecure permissions 0o{mode:o}")]
    InsecureDirectoryPermissions { path: PathBuf, mode: u32 },
    #[error("TLS private key {path} has permissions 0o{mode:o}; expected exactly 0o600")]
    InsecureKeyPermissions { path: PathBuf, mode: u32 },
    #[error("TLS certificate {path} is writable by group or other users: 0o{mode:o}")]
    InsecureCertificatePermissions { path: PathBuf, mode: u32 },
    #[error("TLS identity file is too large: {path}")]
    FileTooLarge { path: PathBuf },
    #[error("TLS identity creation was interrupted; inspect the identity directory: {path}")]
    InterruptedCreation { path: PathBuf },
    #[error(
        "partial TLS identity: {present} exists but {missing} does not; restore the missing file or re-enrol the node"
    )]
    PartialIdentity { present: PathBuf, missing: PathBuf },
    #[error("TLS certificate is corrupt: {0}")]
    CorruptCertificate(String),
    #[error("TLS private key is corrupt: {0}")]
    CorruptPrivateKey(String),
    #[error("TLS certificate and private key do not match: {0}")]
    CertificateKeyMismatch(String),
    #[error("TLS certificate generation failed: {0}")]
    Generation(String),
}

pub struct NodeTlsIdentity {
    pub certificate_der: Vec<u8>,
    pub fingerprint: String,
    pub created: bool,
    server_config: Arc<rustls::ServerConfig>,
}

impl std::fmt::Debug for NodeTlsIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("NodeTlsIdentity")
            .field("fingerprint", &self.fingerprint)
            .field("certificate_bytes", &self.certificate_der.len())
            .field("created", &self.created)
            .field("private_key", &"<redacted>")
            .finish()
    }
}

impl NodeTlsIdentity {
    pub fn rustls_config(&self) -> Arc<rustls::ServerConfig> {
        self.server_config.clone()
    }

    pub fn into_rustls_config(self) -> Arc<rustls::ServerConfig> {
        self.server_config
    }

    fn from_pem(
        certificate_pem: &[u8],
        private_key_pem: &[u8],
        created: bool,
    ) -> Result<Self, TlsIdentityError> {
        let certificate_der = parse_certificate(certificate_pem)?;
        let private_key = parse_private_key(private_key_pem)?;
        let server_config = rustls::ServerConfig::builder_with_provider(
            rustls::crypto::ring::default_provider().into(),
        )
        .with_safe_default_protocol_versions()
        .map_err(|error| TlsIdentityError::CertificateKeyMismatch(error.to_string()))?
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(certificate_der.clone())],
            private_key,
        )
        .map_err(|error| TlsIdentityError::CertificateKeyMismatch(error.to_string()))?;
        let fingerprint = hex::encode(Sha256::digest(&certificate_der));
        Ok(Self {
            certificate_der,
            fingerprint,
            created,
            server_config: Arc::new(server_config),
        })
    }
}

pub fn load_credentials(directory: &Path) -> Result<NodeTlsIdentity, TlsIdentityError> {
    let read = |name| {
        spark_core::identity::credentials::read_credential(directory, name).map_err(|error| {
            TlsIdentityError::Io {
                path: directory.join(name),
                reason: error.to_string(),
            }
        })
    };
    NodeTlsIdentity::from_pem(
        &read(CERTIFICATE_FILE_NAME)?,
        &read(PRIVATE_KEY_FILE_NAME)?,
        false,
    )
}

pub fn load_or_create(identity_dir: &Path) -> Result<NodeTlsIdentity, TlsIdentityError> {
    ensure_identity_directory(identity_dir)?;
    let certificate_path = identity_dir.join(CERTIFICATE_FILE_NAME);
    let key_path = identity_dir.join(PRIVATE_KEY_FILE_NAME);
    let lock_path = identity_dir.join(CREATION_LOCK_FILE_NAME);

    if let Some(lock) = entry(&lock_path)? {
        // Clear stale crash-left creation locks while preserving newer locks as potentially active creation.
        let abandoned = lock
            .modified()
            .ok()
            .and_then(|at| at.elapsed().ok())
            .is_some_and(|age| age > STALE_CREATION_LOCK);
        if abandoned {
            tracing::warn!(
                path = %lock_path.display(),
                "clearing an abandoned TLS identity creation lock"
            );
            std::fs::remove_file(&lock_path).map_err(|error| TlsIdentityError::Io {
                path: lock_path.clone(),
                reason: error.to_string(),
            })?;
        } else {
            return Err(TlsIdentityError::InterruptedCreation { path: lock_path });
        }
    }

    match (entry(&certificate_path)?, entry(&key_path)?) {
        (Some(certificate), Some(key)) => {
            load_existing(&certificate_path, certificate, &key_path, key)
        }
        (Some(_), None) => Err(TlsIdentityError::PartialIdentity {
            present: certificate_path,
            missing: key_path,
        }),
        (None, Some(_)) => Err(TlsIdentityError::PartialIdentity {
            present: key_path,
            missing: certificate_path,
        }),
        (None, None) => create(identity_dir, &certificate_path, &key_path, &lock_path),
    }
}

/// Fingerprint persisted certificates with the same path, size, permission and PEM checks as startup.
pub fn fingerprint_at(certificate_path: &Path) -> Result<String, TlsIdentityError> {
    let metadata = entry(certificate_path)?.ok_or_else(|| TlsIdentityError::Io {
        path: certificate_path.to_path_buf(),
        reason: "certificate does not exist".to_owned(),
    })?;
    let certificate_pem = read_file(certificate_path, metadata, FileKind::Certificate)?;
    let certificate_der = parse_certificate(&certificate_pem)?;
    Ok(hex::encode(Sha256::digest(certificate_der)))
}

fn load_existing(
    certificate_path: &Path,
    certificate_metadata: Metadata,
    key_path: &Path,
    key_metadata: Metadata,
) -> Result<NodeTlsIdentity, TlsIdentityError> {
    let certificate = read_file(
        certificate_path,
        certificate_metadata,
        FileKind::Certificate,
    )?;
    let key = Zeroizing::new(read_file(key_path, key_metadata, FileKind::PrivateKey)?);
    NodeTlsIdentity::from_pem(&certificate, &key, false)
}

fn create(
    identity_dir: &Path,
    certificate_path: &Path,
    key_path: &Path,
    lock_path: &Path,
) -> Result<NodeTlsIdentity, TlsIdentityError> {
    let lock = CreationLock::acquire(lock_path)?;
    let certified = rcgen::generate_simple_self_signed(
        SUBJECT_ALT_NAMES
            .iter()
            .map(|name| (*name).to_owned())
            .collect::<Vec<_>>(),
    )
    .map_err(|error| TlsIdentityError::Generation(error.to_string()))?;
    let certificate_pem = certified.cert.pem().into_bytes();
    let private_key_pem = Zeroizing::new(certified.signing_key.serialize_pem().into_bytes());
    let identity = NodeTlsIdentity::from_pem(&certificate_pem, &private_key_pem, true)?;

    let key_temp = TemporaryFile::write(identity_dir, "node-key", &private_key_pem, KEY_FILE_MODE)?;
    let certificate_temp = TemporaryFile::write(
        identity_dir,
        "node-certificate",
        &certificate_pem,
        CERTIFICATE_FILE_MODE,
    )?;

    publish(&key_temp.path, key_path)?;
    publish(&certificate_temp.path, certificate_path)?;
    sync_directory(identity_dir)?;

    key_temp.remove()?;
    certificate_temp.remove()?;
    lock.remove()?;
    sync_directory(identity_dir)?;
    Ok(identity)
}

fn publish(source: &Path, destination: &Path) -> Result<(), TlsIdentityError> {
    fs::hard_link(source, destination).map_err(|error| io(destination, error))
}

#[derive(Clone, Copy)]
enum FileKind {
    Certificate,
    PrivateKey,
}

fn read_file(
    path: &Path,
    expected_metadata: Metadata,
    kind: FileKind,
) -> Result<Vec<u8>, TlsIdentityError> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let file = options.open(path).map_err(|error| io(path, error))?;
    let opened_metadata = file.metadata().map_err(|error| io(path, error))?;
    if !opened_metadata.file_type().is_file() {
        return Err(TlsIdentityError::NotRegularFile {
            path: path.to_path_buf(),
        });
    }
    if opened_metadata.dev() != expected_metadata.dev()
        || opened_metadata.ino() != expected_metadata.ino()
    {
        return Err(TlsIdentityError::Io {
            path: path.to_path_buf(),
            reason: "file changed while opening it".to_owned(),
        });
    }
    validate_file_mode(path, &opened_metadata, kind)?;
    if opened_metadata.len() > MAX_IDENTITY_FILE_BYTES {
        return Err(TlsIdentityError::FileTooLarge {
            path: path.to_path_buf(),
        });
    }

    let mut bytes = Vec::with_capacity(opened_metadata.len() as usize);
    file.take(MAX_IDENTITY_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| io(path, error))?;
    if bytes.len() as u64 > MAX_IDENTITY_FILE_BYTES {
        return Err(TlsIdentityError::FileTooLarge {
            path: path.to_path_buf(),
        });
    }
    Ok(bytes)
}

fn validate_file_mode(
    path: &Path,
    metadata: &Metadata,
    kind: FileKind,
) -> Result<(), TlsIdentityError> {
    let mode = metadata.permissions().mode() & 0o777;
    match kind {
        FileKind::PrivateKey if mode != KEY_FILE_MODE => {
            Err(TlsIdentityError::InsecureKeyPermissions {
                path: path.to_path_buf(),
                mode,
            })
        }
        FileKind::Certificate if mode & 0o022 != 0 => {
            Err(TlsIdentityError::InsecureCertificatePermissions {
                path: path.to_path_buf(),
                mode,
            })
        }
        _ => Ok(()),
    }
}

fn entry(path: &Path) -> Result<Option<Metadata>, TlsIdentityError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(TlsIdentityError::Symlink {
            path: path.to_path_buf(),
        }),
        Ok(metadata) if !metadata.file_type().is_file() => Err(TlsIdentityError::NotRegularFile {
            path: path.to_path_buf(),
        }),
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(io(path, error)),
    }
}

fn ensure_identity_directory(path: &Path) -> Result<(), TlsIdentityError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            return Err(TlsIdentityError::Symlink {
                path: path.to_path_buf(),
            });
        }
        Ok(metadata) if !metadata.file_type().is_dir() => {
            return Err(TlsIdentityError::NotDirectory {
                path: path.to_path_buf(),
            });
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(path).map_err(|error| io(path, error))?;
            fs::set_permissions(path, fs::Permissions::from_mode(DIRECTORY_MODE))
                .map_err(|error| io(path, error))?;
        }
        Err(error) => return Err(io(path, error)),
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| io(path, error))?;
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o077 != 0 || mode & 0o500 != 0o500 {
        return Err(TlsIdentityError::InsecureDirectoryPermissions {
            path: path.to_path_buf(),
            mode,
        });
    }
    Ok(())
}

fn parse_certificate(pem: &[u8]) -> Result<Vec<u8>, TlsIdentityError> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let text = std::str::from_utf8(pem)
        .map_err(|error| TlsIdentityError::CorruptCertificate(error.to_string()))?;
    let trimmed = text.trim();
    if !trimmed.starts_with(BEGIN)
        || !trimmed.ends_with(END)
        || trimmed.matches(BEGIN).count() != 1
        || trimmed.matches(END).count() != 1
    {
        return Err(TlsIdentityError::CorruptCertificate(
            "expected exactly one PEM certificate".to_owned(),
        ));
    }
    let body = trimmed[BEGIN.len()..trimmed.len() - END.len()]
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect::<String>();
    let der = base64::engine::general_purpose::STANDARD
        .decode(body)
        .map_err(|error| TlsIdentityError::CorruptCertificate(error.to_string()))?;
    if der.is_empty() {
        return Err(TlsIdentityError::CorruptCertificate(
            "empty certificate".to_owned(),
        ));
    }
    Ok(der)
}

fn parse_private_key(pem: &[u8]) -> Result<PrivateKeyDer<'static>, TlsIdentityError> {
    const BEGIN: &str = "-----BEGIN PRIVATE KEY-----";
    const END: &str = "-----END PRIVATE KEY-----";
    let text = std::str::from_utf8(pem)
        .map_err(|error| TlsIdentityError::CorruptPrivateKey(error.to_string()))?;
    let trimmed = text.trim();
    if !trimmed.starts_with(BEGIN)
        || !trimmed.ends_with(END)
        || trimmed.matches(BEGIN).count() != 1
        || trimmed.matches(END).count() != 1
    {
        return Err(TlsIdentityError::CorruptPrivateKey(
            "expected exactly one PKCS#8 PEM private key".to_owned(),
        ));
    }
    PrivateKeyDer::from_pem_slice(pem)
        .map_err(|error| TlsIdentityError::CorruptPrivateKey(error.to_string()))
}

fn sync_directory(path: &Path) -> Result<(), TlsIdentityError> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_DIRECTORY);
    options
        .open(path)
        .map_err(|error| io(path, error))?
        .sync_all()
        .map_err(|error| io(path, error))
}

struct CreationLock {
    path: PathBuf,
    armed: bool,
}

impl CreationLock {
    fn acquire(path: &Path) -> Result<Self, TlsIdentityError> {
        let mut options = OpenOptions::new();
        options
            .write(true)
            .create_new(true)
            .mode(KEY_FILE_MODE)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        let file = options.open(path).map_err(|error| {
            if error.kind() == std::io::ErrorKind::AlreadyExists {
                TlsIdentityError::InterruptedCreation {
                    path: path.to_path_buf(),
                }
            } else {
                io(path, error)
            }
        })?;
        file.set_permissions(fs::Permissions::from_mode(KEY_FILE_MODE))
            .map_err(|error| io(path, error))?;
        file.sync_all().map_err(|error| io(path, error))?;
        Ok(Self {
            path: path.to_path_buf(),
            armed: true,
        })
    }

    fn remove(mut self) -> Result<(), TlsIdentityError> {
        fs::remove_file(&self.path).map_err(|error| io(&self.path, error))?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for CreationLock {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

struct TemporaryFile {
    path: PathBuf,
    armed: bool,
}

impl TemporaryFile {
    fn write(
        directory: &Path,
        label: &str,
        bytes: &[u8],
        mode: u32,
    ) -> Result<Self, TlsIdentityError> {
        let path = directory.join(format!(".{label}.{}.tmp", uuid::Uuid::new_v4()));
        let mut options = OpenOptions::new();
        options
            .write(true)
            .create_new(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
        let mut file = options.open(&path).map_err(|error| io(&path, error))?;
        file.set_permissions(fs::Permissions::from_mode(mode))
            .map_err(|error| io(&path, error))?;
        file.write_all(bytes).map_err(|error| io(&path, error))?;
        file.sync_all().map_err(|error| io(&path, error))?;
        Ok(Self { path, armed: true })
    }

    fn remove(mut self) -> Result<(), TlsIdentityError> {
        fs::remove_file(&self.path).map_err(|error| io(&self.path, error))?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for TemporaryFile {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn io(path: &Path, error: std::io::Error) -> TlsIdentityError {
    TlsIdentityError::Io {
        path: path.to_path_buf(),
        reason: error.to_string(),
    }
}

#[cfg(test)]
#[path = "tls/tests.rs"]
mod tests;

//! Persist a 32-byte Ed25519 seed with exact service-account 0600 custody and matching public record; see RUNTIME-INVARIANTS.md.

use std::fs;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use ed25519_dalek::{SigningKey, VerifyingKey};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use time::OffsetDateTime;
use uuid::Uuid;
use zeroize::Zeroizing;

/// Filename of the private seed (raw 32 bytes, mode `0o600`).
pub const KEY_FILE_NAME: &str = "identity.key";
/// Filename of the public identity record (JSON).
pub const PUBLIC_FILE_NAME: &str = "identity.json";
const KEY_FILE_MODE: u32 = 0o600;
const DIRECTORY_MODE: u32 = 0o700;

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error(
        "identity directory contains {path} but no {KEY_FILE_NAME}; refusing half-written identity"
    )]
    MissingKey { path: PathBuf },
    #[error(
        "{present} exists but {missing} does not. Refusing to continue: creating a new identity \
         here would change this node's authority and invalidate every device grant, and the \
         surviving half is the only copy of what the old one was. Restore the missing file, or \
         remove both to re-enrol this node deliberately."
    )]
    PartialIdentity { present: PathBuf, missing: PathBuf },
    #[error("identity key file {path} has insecure permissions 0o{mode:o} (must be exactly 0o600)")]
    InsecureKeyPermissions { path: PathBuf, mode: u32 },
    #[error("stored identity is corrupt or tampered with: {0}")]
    Corrupt(String),
    #[error(
        "{path} is {kind}; refusing to read or write through it. The identity directory is \
         writable by the service account, so anything that is not a plain file there is a \
         redirection, not a key."
    )]
    NotARegularFile { path: PathBuf, kind: &'static str },
    #[error("stored public identity does not match the private key")]
    PublicMismatch,
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("hex error: {0}")]
    Hex(#[from] hex::FromHexError),
}

/// Public, non-secret node identity record persisted next to the private key.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PublicIdentity {
    pub node_id: Uuid,
    pub node_name: String,
    /// RFC 3339 UTC creation time.
    pub created_at: String,
    /// Hex-encoded Ed25519 public key bytes.
    pub authority_public_key: String,
    /// Hex-encoded SHA-256 of the public key bytes.
    pub authority_fingerprint: String,
}

impl PublicIdentity {
    pub fn verifying_key(&self) -> Result<VerifyingKey, IdentityError> {
        let bytes: [u8; 32] = hex::decode(&self.authority_public_key)?
            .try_into()
            .map_err(|_| IdentityError::Corrupt("public key has wrong length".into()))?;
        Ok(VerifyingKey::from_bytes(&bytes)?)
    }
}

impl From<ed25519_dalek::SignatureError> for IdentityError {
    fn from(_: ed25519_dalek::SignatureError) -> Self {
        IdentityError::Corrupt("invalid Ed25519 public key bytes".into())
    }
}

/// Zeroize seeds on drop; Clone creates a separate in-memory seed copy for test/tool handoff.
#[derive(Clone)]
pub struct NodeIdentity {
    pub public: PublicIdentity,
    authority_seed: Zeroizing<[u8; 32]>,
}

impl std::fmt::Debug for NodeIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NodeIdentity")
            .field("public", &self.public)
            .field("authority_seed", &"<redacted>")
            .finish()
    }
}

impl NodeIdentity {
    /// Create a fresh identity for `node_name` using the OS CSPRNG.
    pub fn generate(node_name: &str) -> Self {
        let mut seed = Zeroizing::new([0u8; 32]);
        rand::rng().fill_bytes(&mut *seed);
        Self::from_seed(seed, node_name)
    }

    /// Build a fresh identity for `node_name` from a new seed.
    fn from_seed(seed: Zeroizing<[u8; 32]>, node_name: &str) -> Self {
        let signing = SigningKey::from_bytes(&seed);
        let verifying = VerifyingKey::from(&signing);
        let fingerprint = hex::encode(Sha256::digest(verifying.to_bytes()));
        Self {
            public: PublicIdentity {
                node_id: Uuid::new_v4(),
                node_name: node_name.to_owned(),
                created_at: OffsetDateTime::now_utc()
                    .format(&time::format_description::well_known::Rfc3339)
                    .expect("RFC3339 formatting is infallible"),
                authority_public_key: hex::encode(verifying.to_bytes()),
                authority_fingerprint: fingerprint,
            },
            authority_seed: seed,
        }
    }

    /// Reconstruct only when the stored public key derives from the loaded seed.
    fn from_loaded(
        seed: Zeroizing<[u8; 32]>,
        public: PublicIdentity,
    ) -> Result<Self, IdentityError> {
        let verifying = VerifyingKey::from_bytes(
            &hex::decode(&public.authority_public_key)?
                .try_into()
                .map_err(|_| IdentityError::Corrupt("public key has wrong length".into()))?,
        )?;
        let signing = SigningKey::from_bytes(&seed);
        if VerifyingKey::from(&signing).to_bytes() != verifying.to_bytes() {
            return Err(IdentityError::PublicMismatch);
        }
        let derived_fingerprint = hex::encode(Sha256::digest(verifying.to_bytes()));
        if derived_fingerprint != public.authority_fingerprint {
            return Err(IdentityError::Corrupt(
                "fingerprint does not match public key".into(),
            ));
        }
        Ok(Self {
            public,
            authority_seed: seed,
        })
    }

    pub fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.authority_seed)
    }

    pub fn fingerprint(&self) -> &str {
        &self.public.authority_fingerprint
    }

    pub fn node_id(&self) -> Uuid {
        self.public.node_id
    }
}

/// Loads or creates node identities on disk.
pub trait IdentityStore: Send + Sync {
    fn load_or_create(&self, node_name: &str) -> Result<NodeIdentity, IdentityError>;
    fn dir(&self) -> &Path;
}

#[derive(Debug)]
pub struct FileIdentityStore {
    dir: PathBuf,
}

/// What the identity directory holds.
enum IdentityState {
    /// Both halves are present.
    Complete,
    /// Neither half is present; this node has never been enrolled.
    Absent,
}

impl FileIdentityStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    fn key_path(&self) -> PathBuf {
        self.dir.join(KEY_FILE_NAME)
    }

    fn public_path(&self) -> PathBuf {
        self.dir.join(PUBLIC_FILE_NAME)
    }

    fn persist(&self, identity: &NodeIdentity) -> Result<(), IdentityError> {
        fs::create_dir_all(&self.dir)?;
        fs::set_permissions(&self.dir, fs::Permissions::from_mode(DIRECTORY_MODE))?;

        // Use exclusive no-follow creation after both identity halves were absent; never truncate or follow a raced replacement.
        let key_path = self.key_path();
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(KEY_FILE_MODE)
            .open(&key_path)?;
        use std::io::Write;
        file.write_all(&*identity.authority_seed)?;
        file.sync_all()?;
        fs::set_permissions(&key_path, fs::Permissions::from_mode(KEY_FILE_MODE))?;

        let json = serde_json::to_vec_pretty(&identity.public)?;
        let public_path = self.public_path();
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(KEY_FILE_MODE)
            .open(&public_path)?;
        file.write_all(&json)?;
        file.sync_all()?;
        fs::set_permissions(&public_path, fs::Permissions::from_mode(KEY_FILE_MODE))?;
        Ok(())
    }

    /// Return None only when both identity halves are absent; partial identities are errors that must not mint new authority.
    pub fn load(&self) -> Result<Option<NodeIdentity>, IdentityError> {
        match self.state()? {
            IdentityState::Absent => Ok(None),
            IdentityState::Complete => self.load_existing().map(Some),
        }
    }

    /// Inspect both halves without following links and refuse partial identities or nonregular files under service-account control.
    fn state(&self) -> Result<IdentityState, IdentityError> {
        let key = self.key_path();
        let public = self.public_path();
        let key_present = Self::regular_file_present(&key)?;
        let public_present = Self::regular_file_present(&public)?;
        match (key_present, public_present) {
            (true, true) => Ok(IdentityState::Complete),
            (false, false) => Ok(IdentityState::Absent),
            (true, false) => Err(IdentityError::PartialIdentity {
                present: key,
                missing: public,
            }),
            (false, true) => Err(IdentityError::PartialIdentity {
                present: public,
                missing: key,
            }),
        }
    }

    /// Accept only regular files; all symlinks, including dangling ones, are refusals.
    fn regular_file_present(path: &Path) -> Result<bool, IdentityError> {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                Err(IdentityError::NotARegularFile {
                    path: path.to_path_buf(),
                    kind: "a symbolic link",
                })
            }
            Ok(metadata) if metadata.is_file() => Ok(true),
            Ok(_) => Err(IdentityError::NotARegularFile {
                path: path.to_path_buf(),
                kind: "not a regular file",
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(IdentityError::Io(error)),
        }
    }

    /// Read a file, refusing to follow a link to it.
    fn read_regular_file(path: &Path) -> Result<Vec<u8>, IdentityError> {
        use std::io::Read;
        let mut file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .map_err(|error| match error.raw_os_error() {
                Some(libc::ELOOP) => IdentityError::NotARegularFile {
                    path: path.to_path_buf(),
                    kind: "a symbolic link",
                },
                _ => IdentityError::Io(error),
            })?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        Ok(bytes)
    }

    fn load_existing(&self) -> Result<NodeIdentity, IdentityError> {
        let key_path = self.key_path();
        if !key_path.exists() {
            return Err(IdentityError::MissingKey {
                path: key_path.clone(),
            });
        }

        let mode = fs::metadata(&key_path)?.permissions().mode() & 0o777;
        // Refuse any key mode other than 0600 without silently repairing evidence of exposure.
        if mode != KEY_FILE_MODE {
            return Err(IdentityError::InsecureKeyPermissions {
                path: key_path,
                mode,
            });
        }

        let seed: Zeroizing<[u8; 32]> = Zeroizing::new(
            Self::read_regular_file(&key_path)?
                .try_into()
                .map_err(|_| IdentityError::Corrupt("private key has wrong length".into()))?,
        );

        let public: PublicIdentity = {
            let bytes = Self::read_regular_file(&self.public_path())?;
            serde_json::from_slice(&bytes)?
        };

        NodeIdentity::from_loaded(seed, public)
    }
}

impl IdentityStore for FileIdentityStore {
    /// Create authority only when both public record and private seed are absent; preserve partial identity for recovery.
    fn load_or_create(&self, node_name: &str) -> Result<NodeIdentity, IdentityError> {
        match self.state()? {
            IdentityState::Complete => self.load_existing(),
            IdentityState::Absent => {
                let identity = NodeIdentity::generate(node_name);
                self.persist(&identity)?;
                Ok(identity)
            }
        }
    }

    fn dir(&self) -> &Path {
        &self.dir
    }
}

/// Explicit development file-store custody; packaged services use PRODUCTION_PRIVATE_KEY_CUSTODY.
pub const PRIVATE_KEY_CUSTODY: &str = "service-account-0600";
pub const PRODUCTION_PRIVATE_KEY_CUSTODY: &str = "root-owned-systemd-credentials";

/// Advertise the first eight hex characters of the node UUID as its short Bonjour identifier.
pub fn short_node_id(node_id: Uuid) -> String {
    node_id.simple().to_string()[..8].to_owned()
}

#[cfg(test)]
#[path = "identity/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "identity/custody_tests.rs"]
mod custody_tests;

#[cfg(test)]
#[path = "identity/partial_identity_tests.rs"]
mod partial_identity_tests;

#[cfg(test)]
#[path = "identity/symlink_tests.rs"]
mod symlink_tests;

pub mod credentials;

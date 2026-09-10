//! Require signed-manifest size/digest and detached Ed25519 verification before dpkg, recording installed versus first-install trust provenance.

use std::io::Read;
use std::path::Path;

use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;
use time::OffsetDateTime;

use crate::manifest::{ReleaseArtifact, ReleaseManifest};
use crate::trust::{ReleaseTrustRoot, TrustError};

/// Length of a raw Ed25519 signature.
pub const SIGNATURE_BYTES: usize = 64;
/// A detached signature file is 64 raw bytes or their base64 text; anything larger is not one.
pub const MAX_SIGNATURE_FILE_BYTES: u64 = 4096;
/// Runtime packages, unlike model weights, must fit this verification memory budget.
pub const MAX_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum VerifyError {
    #[error(transparent)]
    Manifest(#[from] crate::manifest::ManifestError),
    #[error("failed to read {path}: {reason}")]
    Io { path: String, reason: String },
    #[error("artifact is {actual} bytes; the manifest says {expected}")]
    SizeMismatch { expected: u64, actual: u64 },
    #[error("artifact is {size} bytes; verification limit is {limit} bytes")]
    ArtifactTooLarge { size: u64, limit: u64 },
    #[error("artifact digest {actual} does not match the manifest digest {expected}")]
    DigestMismatch { expected: String, actual: String },
    #[error("detached signature is {0} bytes; expected {SIGNATURE_BYTES}")]
    MalformedSignature(usize),
    #[error("no detached signature supplied for {0:?}; refusing to install")]
    MissingSignature(String),
    #[error("manifest has no signature block, so no key can vouch for its artifacts")]
    UnsignedManifest,
    #[error(transparent)]
    Trust(#[from] TrustError),
}

/// Where the verifying trust root came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustRootSource {
    /// Use the prior package's installed root, which the updating machine did not select.
    Installed,
    /// The root the installer carried in, used only when the Spark has none.
    Supplied,
}

/// What [`verify_artifact`] proved.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct VerificationReport {
    pub name: String,
    pub size: u64,
    pub sha256: String,
    /// The key whose detached signature covered these exact bytes.
    pub signature_key_id: String,
    pub trust_root_source: TrustRootSource,
}

/// Group artifact, trust root, signature and signing-key evidence to prevent positional transposition.
pub struct ArtifactVerification<'a> {
    pub artifact: &'a ReleaseArtifact,
    pub channel: &'a str,
    /// The root to verify against, and where it came from.
    pub trust_root: &'a ReleaseTrustRoot,
    pub trust_root_source: TrustRootSource,
    /// Raw detached signature bytes. Never optional.
    pub signature: &'a [u8],
    /// The key id the manifest named.
    pub key_id: &'a str,
    pub at: OffsetDateTime,
}

/// Require artifact size, digest and detached signature verification with no bypass option.
pub fn verify_artifact(
    path: &Path,
    request: &ArtifactVerification<'_>,
) -> Result<VerificationReport, VerifyError> {
    let ArtifactVerification {
        artifact,
        channel,
        trust_root,
        trust_root_source,
        signature,
        key_id,
        at,
    } = *request;

    if signature.is_empty() {
        return Err(VerifyError::MissingSignature(artifact.name.clone()));
    }
    if signature.len() != SIGNATURE_BYTES {
        return Err(VerifyError::MalformedSignature(signature.len()));
    }

    let io_error = |error: std::io::Error| VerifyError::Io {
        path: path.display().to_string(),
        reason: error.to_string(),
    };
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(io_error)?;
    let metadata = file.metadata().map_err(io_error)?;
    if !metadata.is_file() {
        return Err(io_error(std::io::Error::other(
            "artifact is not a regular file",
        )));
    }
    let actual_size = metadata.len();
    if actual_size > MAX_ARTIFACT_BYTES || artifact.size > MAX_ARTIFACT_BYTES {
        return Err(VerifyError::ArtifactTooLarge {
            size: actual_size.max(artifact.size),
            limit: MAX_ARTIFACT_BYTES,
        });
    }
    if actual_size != artifact.size {
        return Err(VerifyError::SizeMismatch {
            expected: artifact.size,
            actual: actual_size,
        });
    }

    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(MAX_ARTIFACT_BYTES as usize + 1)
        .map_err(|error| io_error(std::io::Error::other(error)))?;
    file.take(MAX_ARTIFACT_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() as u64 != artifact.size {
        return Err(VerifyError::SizeMismatch {
            expected: artifact.size,
            actual: bytes.len() as u64,
        });
    }

    let digest = hex::encode(Sha256::digest(&bytes));
    if digest != artifact.sha256 {
        return Err(VerifyError::DigestMismatch {
            expected: artifact.sha256.clone(),
            actual: digest,
        });
    }

    trust_root.verify_detached(key_id, &bytes, signature, at, channel)?;

    Ok(VerificationReport {
        name: artifact.name.clone(),
        size: actual_size,
        sha256: digest,
        signature_key_id: key_id.to_owned(),
        trust_root_source,
    })
}

/// Verify every listed artifact using signature_for; one missing or invalid detached signature rejects the entire release.
pub fn verify_release<F>(
    manifest: &ReleaseManifest,
    artifact_dir: &Path,
    trust_root: &ReleaseTrustRoot,
    trust_root_source: TrustRootSource,
    at: OffsetDateTime,
    mut signature_for: F,
) -> Result<Vec<VerificationReport>, VerifyError>
where
    F: FnMut(&ReleaseArtifact) -> Option<Vec<u8>>,
{
    let key_id = manifest
        .signature
        .as_ref()
        .map(|signature| signature.key_id.clone())
        .ok_or(VerifyError::UnsignedManifest)?;

    let mut reports = Vec::with_capacity(manifest.artifacts.len());
    for artifact in &manifest.artifacts {
        // Validate artifact paths here too because callers may construct manifests without JSON parsing.
        artifact.validate()?;
        let signature = signature_for(artifact)
            .ok_or_else(|| VerifyError::MissingSignature(artifact.name.clone()))?;
        reports.push(verify_artifact(
            &artifact_dir.join(&artifact.name),
            &ArtifactVerification {
                artifact,
                channel: &manifest.channel,
                trust_root,
                trust_root_source,
                signature: &signature,
                key_id: &key_id,
                at,
            },
        )?);
    }
    Ok(reports)
}

/// Accept detached signatures as 64 raw bytes or release tooling's unpadded base64url text.
pub fn read_signature(path: &Path) -> Result<Vec<u8>, VerifyError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    let io_error = |error: std::io::Error| VerifyError::Io {
        path: path.display().to_string(),
        reason: error.to_string(),
    };
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(io_error)?;
    let metadata = file.metadata().map_err(io_error)?;
    if !metadata.is_file() {
        return Err(io_error(std::io::Error::other(
            "signature is not a regular file",
        )));
    }
    if metadata.len() > MAX_SIGNATURE_FILE_BYTES {
        return Err(VerifyError::MalformedSignature(metadata.len() as usize));
    }
    let mut bytes = Vec::new();
    file.take(MAX_SIGNATURE_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() as u64 > MAX_SIGNATURE_FILE_BYTES {
        return Err(VerifyError::MalformedSignature(bytes.len()));
    }
    if bytes.len() == SIGNATURE_BYTES {
        return Ok(bytes);
    }
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| VerifyError::MalformedSignature(bytes.len()))?
        .trim();
    let decoded = URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| VerifyError::MalformedSignature(bytes.len()))?;
    if decoded.len() != SIGNATURE_BYTES {
        return Err(VerifyError::MalformedSignature(decoded.len()));
    }
    Ok(decoded)
}

#[cfg(test)]
#[path = "verify/tests.rs"]
mod tests;

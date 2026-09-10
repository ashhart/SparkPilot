//! Enforce release key windows, revocation and purposes; schema-1 direct trust permits dev/lab only, as documented in RUNTIME-INVARIANTS.md.

use std::path::Path;

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::manifest::{ManifestError, ReleaseManifest, SIGNATURE_ALGORITHM};

/// Current trust document schema.
pub const TRUST_SCHEMA: u32 = 1;
pub const DELEGATED_TRUST_SCHEMA: u32 = 2;
pub const DELEGATION_PURPOSE: &str = "release-delegation";

/// Purpose required to sign a release manifest.
pub const MANIFEST_PURPOSE: &str = "release-manifest";
/// Purpose required to sign a release artifact (the `.deb` itself).
pub const PACKAGE_PURPOSE: &str = "release-package";
/// Purpose required to sign a model catalogue. Never accepted here.
pub const CATALOGUE_PURPOSE: &str = "model-catalogue";
/// Every purpose this build understands.
pub const PURPOSES: &[&str] = &[
    MANIFEST_PURPOSE,
    PACKAGE_PURPOSE,
    CATALOGUE_PURPOSE,
    DELEGATION_PURPOSE,
];

/// Schema-1 direct trust may authorize only these nonproduction channels.
pub const DIRECT_TRUST_CHANNELS: &[&str] = &["dev", "lab"];
/// Where the package installs the trust root.
pub const INSTALLED_TRUST_ROOT: &str = "/usr/share/spark-runtime/trust/release-keys.json";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum TrustError {
    #[error("trust root is not valid JSON: {0}")]
    Json(String),
    #[error("trust root schema {0} is not supported (expected {TRUST_SCHEMA})")]
    UnsupportedSchema(u32),
    #[error("trust root contains no keys")]
    Empty,
    #[error("trust root lists key id {0:?} more than once")]
    DuplicateKeyId(String),
    #[error("trust root key {key_id:?} is invalid: {reason}")]
    InvalidKey { key_id: String, reason: String },
    #[error("no trusted key with id {0:?}")]
    UnknownKeyId(String),
    #[error("release key {0:?} is revoked")]
    RevokedKey(String),
    #[error("release key {key_id:?} is not valid at {at}")]
    KeyNotValidYet { key_id: String, at: String },
    #[error("release key {key_id:?} is not authorised for channel {channel:?}")]
    ChannelNotAuthorised { key_id: String, channel: String },
    #[error("release key {key_id:?} has purposes {purposes:?} and may not be used to {needed}")]
    PurposeNotAuthorised {
        key_id: String,
        purposes: Vec<String>,
        needed: &'static str,
    },
    #[error(
        "channel {0:?} requires a trust root whose keys are delegated by an offline root; \
         this build only implements the schema 1 direct-trust format, which is limited to \
         the dev and lab channels"
    )]
    DelegationRequired(String),
    #[error("signature does not verify against release key {0:?}")]
    SignatureInvalid(String),
    #[error("invalid offline-root delegation: {0}")]
    Delegation(String),
    #[error(transparent)]
    Manifest(#[from] ManifestError),
    #[error("failed to read trust root: {0}")]
    Io(String),
}

/// One trusted release-signing key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TrustedKey {
    pub key_id: String,
    pub algorithm: String,
    /// Encode the Ed25519 public key as 64 hex characters, matching catalogue trust storage.
    pub public_key: String,
    /// Channels this key may sign for.
    pub channels: Vec<String>,
    /// What this key may sign. A manifest key is not a catalogue key.
    pub purposes: Vec<String>,
    pub not_before: String,
    pub not_after: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revoked_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

/// The parsed trust root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleaseTrustRoot {
    pub schema: u32,
    pub keys: Vec<TrustedKey>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub root_keys: Vec<TrustedKey>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_delegation_version: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delegation: Option<delegation::Delegation>,
}

/// A verified manifest plus the key that vouched for it.
#[derive(Debug, Clone)]
pub struct VerifiedManifest {
    pub manifest: ReleaseManifest,
    pub key_id: String,
}

impl ReleaseTrustRoot {
    pub fn load(path: &Path) -> Result<Self, TrustError> {
        let bytes = std::fs::read(path).map_err(|e| TrustError::Io(e.to_string()))?;
        Self::from_json(&bytes)
    }

    pub fn from_json(bytes: &[u8]) -> Result<Self, TrustError> {
        let root: Self =
            serde_json::from_slice(bytes).map_err(|e| TrustError::Json(e.to_string()))?;
        if ![TRUST_SCHEMA, DELEGATED_TRUST_SCHEMA].contains(&root.schema) {
            return Err(TrustError::UnsupportedSchema(root.schema));
        }
        if root.keys.is_empty() {
            return Err(TrustError::Empty);
        }
        // Reject duplicate key ids so first-match lookup cannot hide changed scope, validity or revocation.
        let mut seen = std::collections::BTreeSet::new();
        for key in &root.keys {
            if !seen.insert(key.key_id.as_str()) {
                return Err(TrustError::DuplicateKeyId(key.key_id.clone()));
            }
            key.verifying_key()?;
            key.window()?;
            key.revocation()?;
        }
        root.validate_delegation_shape()?;
        Ok(root)
    }

    /// Verify signature and key policy at the supplied time, distinguishing policy refusals from tampering.
    pub fn verify_manifest(
        &self,
        bytes: &[u8],
        at: OffsetDateTime,
    ) -> Result<VerifiedManifest, TrustError> {
        let manifest = ReleaseManifest::parse(bytes)?;
        let signature = manifest.signature()?;
        let key = self
            .keys
            .iter()
            .find(|key| key.key_id == signature.key_id)
            .ok_or_else(|| TrustError::UnknownKeyId(signature.key_id.clone()))?;

        key.assert_usable(
            at,
            &manifest.channel,
            MANIFEST_PURPOSE,
            "sign release manifests",
        )?;

        self.authorize_channel(at, &manifest.channel)?;
        let verifying_key = key.verifying_key()?;
        let signature_bytes = manifest.signature_bytes()?;
        let canonical = manifest.canonical_bytes()?;
        verifying_key
            .verify(&canonical, &Signature::from_bytes(&signature_bytes))
            .map_err(|_| TrustError::SignatureInvalid(key.key_id.clone()))?;

        Ok(VerifiedManifest {
            key_id: key.key_id.clone(),
            manifest,
        })
    }

    /// Verify a detached signature over arbitrary bytes (the `.deb` itself).
    pub fn verify_detached(
        &self,
        key_id: &str,
        payload: &[u8],
        signature: &[u8],
        at: OffsetDateTime,
        channel: &str,
    ) -> Result<(), TrustError> {
        let key = self
            .keys
            .iter()
            .find(|key| key.key_id == key_id)
            .ok_or_else(|| TrustError::UnknownKeyId(key_id.to_owned()))?;
        key.assert_usable(at, channel, PACKAGE_PURPOSE, "sign release packages")?;
        self.authorize_channel(at, channel)?;

        let signature: [u8; 64] = signature
            .try_into()
            .map_err(|_| TrustError::SignatureInvalid(key_id.to_owned()))?;
        key.verifying_key()?
            .verify(payload, &Signature::from_bytes(&signature))
            .map_err(|_| TrustError::SignatureInvalid(key_id.to_owned()))
    }
}

impl TrustedKey {
    pub fn verifying_key(&self) -> Result<VerifyingKey, TrustError> {
        let invalid = |reason: &str| TrustError::InvalidKey {
            key_id: self.key_id.clone(),
            reason: reason.to_owned(),
        };
        if self.key_id.trim().is_empty() {
            return Err(invalid("key_id is empty"));
        }
        if self.algorithm != SIGNATURE_ALGORITHM {
            return Err(invalid("algorithm is not ed25519"));
        }
        if self.channels.is_empty() {
            return Err(invalid("key authorises no channel"));
        }
        if self.purposes.is_empty() {
            return Err(invalid("key authorises no purpose"));
        }
        if let Some(unknown) = self
            .purposes
            .iter()
            .find(|purpose| !PURPOSES.contains(&purpose.as_str()))
        {
            return Err(TrustError::InvalidKey {
                key_id: self.key_id.clone(),
                reason: format!("unknown purpose {unknown:?}"),
            });
        }
        let bytes = hex::decode(&self.public_key).map_err(|_| invalid("public_key is not hex"))?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| invalid("public_key is not 32 bytes"))?;
        VerifyingKey::from_bytes(&bytes).map_err(|_| invalid("public_key is not on the curve"))
    }

    fn window(&self) -> Result<(OffsetDateTime, OffsetDateTime), TrustError> {
        let invalid = |reason: &str| TrustError::InvalidKey {
            key_id: self.key_id.clone(),
            reason: reason.to_owned(),
        };
        let not_before = OffsetDateTime::parse(&self.not_before, &Rfc3339)
            .map_err(|_| invalid("not_before is not RFC 3339"))?;
        let not_after = OffsetDateTime::parse(&self.not_after, &Rfc3339)
            .map_err(|_| invalid("not_after is not RFC 3339"))?;
        if not_after <= not_before {
            return Err(invalid("validity window ends before it starts"));
        }
        Ok((not_before, not_after))
    }

    /// Treat malformed revocation timestamps as errors so a withdrawn key cannot remain usable by typo.
    fn revocation(&self) -> Result<Option<OffsetDateTime>, TrustError> {
        match self.revoked_at.as_deref() {
            None => Ok(None),
            Some(text) => OffsetDateTime::parse(text, &Rfc3339)
                .map(Some)
                .map_err(|_| TrustError::InvalidKey {
                    key_id: self.key_id.clone(),
                    reason: format!("revoked_at {text:?} is not RFC 3339"),
                }),
        }
    }

    fn assert_usable(
        &self,
        at: OffsetDateTime,
        channel: &str,
        purpose: &str,
        needed: &'static str,
    ) -> Result<(), TrustError> {
        if self.revocation()?.is_some() {
            return Err(TrustError::RevokedKey(self.key_id.clone()));
        }
        let (not_before, not_after) = self.window()?;
        if at < not_before || at >= not_after {
            return Err(TrustError::KeyNotValidYet {
                key_id: self.key_id.clone(),
                at: at.format(&Rfc3339).unwrap_or_else(|_| at.to_string()),
            });
        }
        if !self.channels.iter().any(|value| value == channel) {
            return Err(TrustError::ChannelNotAuthorised {
                key_id: self.key_id.clone(),
                channel: channel.to_owned(),
            });
        }
        if !self.purposes.iter().any(|value| value == purpose) {
            return Err(TrustError::PurposeNotAuthorised {
                key_id: self.key_id.clone(),
                purposes: self.purposes.clone(),
                needed,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "trust/tests.rs"]
mod tests;

mod delegation;

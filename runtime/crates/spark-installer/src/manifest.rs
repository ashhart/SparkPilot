//! Implement the authoritative release schema and shared canonical signature algorithm documented in RUNTIME-INVARIANTS.md.

use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

/// Channels a release may be published on.
pub const CHANNELS: &[&str] = &["dev", "lab", "beta", "stable"];
/// The only architecture the product ships (DGX Spark is Arm64).
pub const ARCHITECTURE: &str = "aarch64";
/// The only manifest signature algorithm this build accepts.
pub const SIGNATURE_ALGORITHM: &str = "ed25519";

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ManifestError {
    #[error("manifest is not valid JSON: {0}")]
    Json(String),
    #[error("manifest is missing its signature block")]
    MissingSignature,
    #[error("unsupported signature algorithm {0:?} (expected {SIGNATURE_ALGORITHM})")]
    UnsupportedAlgorithm(String),
    #[error("signature value is not 64 base64url bytes")]
    MalformedSignature,
    #[error("unsupported channel {0:?}")]
    UnsupportedChannel(String),
    #[error("version {0:?} is not a release version")]
    InvalidVersion(String),
    #[error("released_at {0:?} is not an RFC 3339 timestamp")]
    InvalidReleasedAt(String),
    #[error("api_version {0} is below the minimum of 1")]
    InvalidApiVersion(u32),
    #[error("minimum_dgx_os is empty")]
    MissingMinimumDgxOs,
    #[error("manifest lists no artifacts")]
    NoArtifacts,
    #[error("artifact {name:?}: {reason}")]
    InvalidArtifact { name: String, reason: String },
    #[error("no artifact named {0:?} in this manifest")]
    ArtifactNotFound(String),
    #[error("manifest lists {0} artifacts; name the one to install")]
    AmbiguousArtifact(usize),
}

/// One downloadable release artifact.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleaseArtifact {
    pub name: String,
    pub architecture: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
    pub signature_url: String,
}

/// The manifest's detached signature block.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestSignature {
    pub key_id: String,
    pub algorithm: String,
    pub value: String,
}

/// A release manifest exactly as published.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReleaseManifest {
    pub version: String,
    pub channel: String,
    pub released_at: String,
    pub minimum_dgx_os: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maximum_dgx_os: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_version: Option<u32>,
    pub artifacts: Vec<ReleaseArtifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<ManifestSignature>,
}

impl ReleaseManifest {
    /// Parse and validate structure before signature verification.
    pub fn parse(bytes: &[u8]) -> Result<Self, ManifestError> {
        let manifest: Self =
            serde_json::from_slice(bytes).map_err(|e| ManifestError::Json(e.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// Produce shared canonical signature bytes; see RUNTIME-INVARIANTS.md.
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ManifestError> {
        let mut unsigned = self.clone();
        unsigned.signature = None; // 1
        let mut value: serde_json::Value =
            serde_json::to_value(&unsigned).map_err(|e| ManifestError::Json(e.to_string()))?;
        strip_nulls(&mut value); // 2
        // BTreeMap orders keys; serde_json emits compact JSON with required escaping only.
        serde_json::to_vec(&value).map_err(|e| ManifestError::Json(e.to_string()))
    }

    /// The signature block, or [`ManifestError::MissingSignature`].
    pub fn signature(&self) -> Result<&ManifestSignature, ManifestError> {
        let signature = self
            .signature
            .as_ref()
            .ok_or(ManifestError::MissingSignature)?;
        if signature.algorithm != SIGNATURE_ALGORITHM {
            return Err(ManifestError::UnsupportedAlgorithm(
                signature.algorithm.clone(),
            ));
        }
        Ok(signature)
    }

    /// Decode the 64 raw signature bytes.
    pub fn signature_bytes(&self) -> Result<[u8; 64], ManifestError> {
        decode_signature(&self.signature()?.value)
    }

    /// Require an artifact name when multiple artifacts exist so selection cannot silently change the requested install.
    pub fn artifact(&self, name: Option<&str>) -> Result<&ReleaseArtifact, ManifestError> {
        match name {
            Some(name) => self
                .artifacts
                .iter()
                .find(|artifact| artifact.name == name)
                .ok_or_else(|| ManifestError::ArtifactNotFound(name.to_owned())),
            None if self.artifacts.len() == 1 => Ok(&self.artifacts[0]),
            None => Err(ManifestError::AmbiguousArtifact(self.artifacts.len())),
        }
    }

    /// Derive a retry-stable identity from the selected, signed Debian artifact, including its revision.
    pub fn release_id_for_artifact(&self, artifact_name: &str) -> String {
        let version = artifact_name
            .strip_prefix("spark-runtime_")
            .and_then(|name| name.strip_suffix("_arm64.deb"))
            .filter(|version| version.starts_with(&format!("{}-", self.version)))
            .filter(|version| is_release_version(version))
            .unwrap_or(&self.version);
        format!("{}-{version}", self.channel)
    }

    fn validate(&self) -> Result<(), ManifestError> {
        if !CHANNELS.contains(&self.channel.as_str()) {
            return Err(ManifestError::UnsupportedChannel(self.channel.clone()));
        }
        if !is_release_version(&self.version) {
            return Err(ManifestError::InvalidVersion(self.version.clone()));
        }
        // Enforce schema date-time and positive-version constraints before accepting a signed manifest.
        if OffsetDateTime::parse(&self.released_at, &Rfc3339).is_err() {
            return Err(ManifestError::InvalidReleasedAt(self.released_at.clone()));
        }
        if self.api_version == Some(0) {
            return Err(ManifestError::InvalidApiVersion(0));
        }
        if self.minimum_dgx_os.trim().is_empty() {
            return Err(ManifestError::MissingMinimumDgxOs);
        }
        if self.artifacts.is_empty() {
            return Err(ManifestError::NoArtifacts);
        }
        for artifact in &self.artifacts {
            artifact.validate()?;
        }
        if let Some(signature) = self.signature.as_ref() {
            if signature.algorithm != SIGNATURE_ALGORITHM {
                return Err(ManifestError::UnsupportedAlgorithm(
                    signature.algorithm.clone(),
                ));
            }
            if signature.key_id.trim().is_empty() {
                return Err(ManifestError::MalformedSignature);
            }
            decode_signature(&signature.value)?;
        }
        Ok(())
    }
}

impl ReleaseArtifact {
    pub(crate) fn validate(&self) -> Result<(), ManifestError> {
        let invalid = |reason: &str| ManifestError::InvalidArtifact {
            name: self.name.clone(),
            reason: reason.to_owned(),
        };
        if self.name.trim().is_empty() {
            return Err(invalid("name is empty"));
        }
        if self.architecture != ARCHITECTURE {
            return Err(invalid("architecture is not aarch64"));
        }
        if self.size == 0 {
            return Err(invalid("size is zero"));
        }
        if !is_sha256_hex(&self.sha256) {
            return Err(invalid("sha256 is not 64 lowercase hex characters"));
        }
        // Require authenticated HTTPS transport in addition to digest verification.
        if !self.url.starts_with("https://") {
            return Err(invalid("url is not https"));
        }
        if !self.signature_url.starts_with("https://") {
            return Err(invalid("signature_url is not https"));
        }
        // Require a plain filename before joining the artifact directory; a signature does not authorize path traversal.
        if self.name.is_empty()
            || self.name == "."
            || self.name == ".."
            || self.name.contains('/')
            || self.name.contains('\\')
            || self.name.contains('\0')
        {
            return Err(invalid("name is not a plain file name"));
        }
        Ok(())
    }
}

/// `^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$` without a regex dependency.
pub fn is_release_version(version: &str) -> bool {
    let (core, suffix) = match version.find(['+', '-']) {
        Some(index) => (&version[..index], Some(&version[index + 1..])),
        None => (version, None),
    };
    let mut parts = core.split('.');
    let numeric = |part: Option<&str>| {
        part.map(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
            .unwrap_or(false)
    };
    if !numeric(parts.next()) || !numeric(parts.next()) || !numeric(parts.next()) {
        return false;
    }
    if parts.next().is_some() {
        return false;
    }
    match suffix {
        None => true,
        Some(suffix) => {
            !suffix.is_empty()
                && suffix
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        }
    }
}

/// 64 lowercase hex characters, as the schema requires.
pub fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Remove explicit null object members so they canonicalize identically to omitted members.
pub fn strip_nulls(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(map) => {
            map.retain(|_, member| !member.is_null());
            for member in map.values_mut() {
                strip_nulls(member);
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                strip_nulls(item);
            }
        }
        _ => {}
    }
}

fn decode_signature(value: &str) -> Result<[u8; 64], ManifestError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ManifestError::MalformedSignature)?;
    bytes
        .try_into()
        .map_err(|_| ManifestError::MalformedSignature)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest_json() -> String {
        serde_json::json!({
            "version": "0.1.0",
            "channel": "dev",
            "released_at": "2026-08-27T00:00:00Z",
            "minimum_dgx_os": "7.0",
            "api_version": 1,
            "artifacts": [{
                "name": "spark-runtime_0.1.0-1_arm64.deb",
                "architecture": "aarch64",
                "url": "https://releases.example.invalid/a.deb",
                "size": 1234,
                "sha256": "a".repeat(64),
                "signature_url": "https://releases.example.invalid/a.deb.sig"
            }],
            "signature": {
                "key_id": "spark-release-dev-2026a",
                "algorithm": "ed25519",
                "value": "A".repeat(86)
            }
        })
        .to_string()
    }

    #[test]
    fn parses_a_schema_shaped_manifest() {
        let manifest = ReleaseManifest::parse(manifest_json().as_bytes()).unwrap();
        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(manifest.artifacts.len(), 1);
        assert_eq!(manifest.artifact(None).unwrap().size, 1234);
    }

    #[test]
    fn canonical_bytes_omit_the_signature_and_sort_keys() {
        let manifest = ReleaseManifest::parse(manifest_json().as_bytes()).unwrap();
        let canonical = String::from_utf8(manifest.canonical_bytes().unwrap()).unwrap();
        assert!(!canonical.contains("signature\":{"));
        assert!(canonical.starts_with(r#"{"api_version":1,"artifacts":[{"architecture":"#));
        assert!(!canonical.contains(' '));
        // Nested objects sort too.
        let artifact_start = canonical.find("[{").unwrap();
        assert!(canonical[artifact_start..].starts_with(r#"[{"architecture":"aarch64","name":"#));
    }

    #[test]
    fn canonical_bytes_are_stable_across_input_key_order() {
        let reordered = serde_json::json!({
            "signature": {
                "value": "A".repeat(86),
                "algorithm": "ed25519",
                "key_id": "spark-release-dev-2026a"
            },
            "artifacts": [{
                "sha256": "a".repeat(64),
                "signature_url": "https://releases.example.invalid/a.deb.sig",
                "url": "https://releases.example.invalid/a.deb",
                "size": 1234,
                "architecture": "aarch64",
                "name": "spark-runtime_0.1.0-1_arm64.deb"
            }],
            "api_version": 1,
            "minimum_dgx_os": "7.0",
            "released_at": "2026-08-27T00:00:00Z",
            "channel": "dev",
            "version": "0.1.0"
        })
        .to_string();

        let a = ReleaseManifest::parse(manifest_json().as_bytes()).unwrap();
        let b = ReleaseManifest::parse(reordered.as_bytes()).unwrap();
        assert_eq!(a.canonical_bytes().unwrap(), b.canonical_bytes().unwrap());
    }

    #[test]
    fn absent_optional_fields_are_omitted_not_null() {
        let value = serde_json::json!({
            "version": "0.1.0",
            "channel": "dev",
            "released_at": "2026-08-27T00:00:00Z",
            "minimum_dgx_os": "7.0",
            "artifacts": [{
                "name": "a.deb",
                "architecture": "aarch64",
                "url": "https://x.invalid/a.deb",
                "size": 1,
                "sha256": "b".repeat(64),
                "signature_url": "https://x.invalid/a.deb.sig"
            }],
            "signature": {"key_id": "k", "algorithm": "ed25519", "value": "A".repeat(86)}
        })
        .to_string();
        let manifest = ReleaseManifest::parse(value.as_bytes()).unwrap();
        let canonical = String::from_utf8(manifest.canonical_bytes().unwrap()).unwrap();
        assert!(!canonical.contains("null"));
        assert!(!canonical.contains("maximum_dgx_os"));
        assert!(!canonical.contains("api_version"));
    }

    #[test]
    fn rejects_unknown_members() {
        let value = manifest_json().replace(r#""channel""#, r#""surprise":1,"channel""#);
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::Json(_))
        ));
    }

    #[test]
    fn rejects_non_aarch64_artifacts() {
        let value = manifest_json().replace("aarch64", "x86_64");
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::InvalidArtifact { .. })
        ));
    }

    #[test]
    fn rejects_plaintext_artifact_urls() {
        let value = manifest_json().replace(
            "https://releases.example.invalid/a.deb\"",
            "http://releases.example.invalid/a.deb\"",
        );
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::InvalidArtifact { .. })
        ));
    }

    #[test]
    fn rejects_uppercase_digests() {
        let value = manifest_json().replace(&"a".repeat(64), &"A".repeat(64));
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::InvalidArtifact { .. })
        ));
    }

    #[test]
    fn rejects_unsupported_signature_algorithms() {
        // Refuse schema-valid but unsupported cosign signatures; this build verifies Ed25519 only.
        let value = manifest_json().replace(r#""algorithm":"ed25519""#, r#""algorithm":"cosign""#);
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::UnsupportedAlgorithm(_))
        ));
    }

    #[test]
    fn rejects_short_signatures() {
        let value = manifest_json().replace(&"A".repeat(86), "AAAA");
        assert!(matches!(
            ReleaseManifest::parse(value.as_bytes()),
            Err(ManifestError::MalformedSignature)
        ));
    }

    #[test]
    fn ambiguous_artifact_selection_is_an_error() {
        let mut manifest = ReleaseManifest::parse(manifest_json().as_bytes()).unwrap();
        let mut second = manifest.artifacts[0].clone();
        second.name = "other.deb".into();
        manifest.artifacts.push(second);
        assert!(matches!(
            manifest.artifact(None),
            Err(ManifestError::AmbiguousArtifact(2))
        ));
        assert!(manifest.artifact(Some("other.deb")).is_ok());
        assert!(matches!(
            manifest.artifact(Some("nope.deb")),
            Err(ManifestError::ArtifactNotFound(_))
        ));
    }

    #[test]
    fn version_shapes() {
        assert!(is_release_version("0.1.0"));
        assert!(is_release_version("10.20.30"));
        assert!(is_release_version("1.2.3-rc.1"));
        assert!(is_release_version("1.2.3+build.5"));
        assert!(!is_release_version("1.2"));
        assert!(!is_release_version("1.2.3.4"));
        assert!(!is_release_version("v1.2.3"));
        assert!(!is_release_version("1.2.x"));
        assert!(!is_release_version("1.2.3-"));
    }
}

#[cfg(test)]
mod artifact_name_tests {
    use super::*;

    fn artifact(name: &str) -> ReleaseArtifact {
        ReleaseArtifact {
            name: name.to_owned(),
            architecture: ARCHITECTURE.to_owned(),
            size: 1,
            sha256: "a".repeat(64),
            url: "https://example.invalid/a".to_owned(),
            signature_url: "https://example.invalid/a.sig".to_owned(),
        }
    }

    /// Artifact names must not escape the directory used by verify_release (L39).
    #[test]
    fn an_artifact_name_must_be_a_plain_file_name() {
        for refused in ["", ".", "..", "../../etc/passwd", "a/b", "a\\b"] {
            assert!(
                artifact(refused).validate().is_err(),
                "{refused:?} must be refused"
            );
        }
        assert!(
            artifact("spark-runtime_0.1.11-1_arm64.deb")
                .validate()
                .is_ok()
        );
    }
}

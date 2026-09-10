//! The Spark signs exact build recipes; the Mac signs Xcode result evidence with its paired device key.

use ed25519_dalek::{Signature as Ed25519Signature, Signer as _, Verifier as _};
use p256::ecdsa::{Signature as P256Signature, VerifyingKey};
use p256::pkcs8::DecodePublicKey as _;
use serde::{Deserialize, Serialize};
use spark_core::identity::{NodeIdentity, PublicIdentity};
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::crypto::{base64url_decode, base64url_encode, sha256_hex};

pub const PROTOCOL_VERSION: &str = "SPARK-BUILD-1";
pub const MAX_BUILD_OUTPUT_BYTES: usize = 1024 * 1024;
pub const MAX_ARTIFACT_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_ARTIFACT_TOTAL_BYTES: u64 = 32 * 1024 * 1024;
pub const MAX_ARTIFACTS: u16 = 16;
pub const MAX_TEST_FAILURES: usize = 1_000;
pub const MAX_DIAGNOSTICS: usize = 5_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildRequirements {
    pub platform: String,
    pub architecture: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_xcode_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdk: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub simulator: Option<String>,
    #[serde(default)]
    pub signing_required: bool,
}

impl Default for BuildRequirements {
    fn default() -> Self {
        Self {
            platform: "macOS".into(),
            architecture: "arm64".into(),
            minimum_xcode_version: None,
            sdk: None,
            simulator: None,
            signing_required: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildSourceTicket {
    pub ticket_id: Uuid,
    pub repository_url: Option<String>,
    pub commit: String,
    pub source_sha256: String,
    pub max_bytes: u64,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildArtifactTicket {
    pub ticket_id: Uuid,
    pub upload_path_template: String,
    pub max_file_bytes: u64,
    pub max_total_bytes: u64,
    pub max_files: u16,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildRecipePayload {
    pub protocol: String,
    pub build_id: Uuid,
    pub worker_id: Uuid,
    pub claim_generation: i64,
    pub project_id: Uuid,
    pub commit: String,
    pub source_sha256: String,
    pub scheme: String,
    pub configuration: String,
    pub destination: String,
    pub actions: Vec<String>,
    pub timeout_seconds: i64,
    pub requirements: BuildRequirements,
    pub source_ticket: BuildSourceTicket,
    pub artifact_ticket: BuildArtifactTicket,
    pub issued_at: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SignedBuildRecipe {
    pub payload: BuildRecipePayload,
    pub authority_public_key: String,
    pub authority_fingerprint: String,
    pub signature: String,
}

impl SignedBuildRecipe {
    pub fn issue(identity: &NodeIdentity, payload: BuildRecipePayload) -> Result<Self, String> {
        let canonical = canonical_json(&payload).map_err(|error| error.to_string())?;
        let signature = identity.signing_key().sign(&canonical);
        Ok(Self {
            payload,
            authority_public_key: identity.public.authority_public_key.clone(),
            authority_fingerprint: identity.public.authority_fingerprint.clone(),
            signature: base64url_encode(&signature.to_bytes()),
        })
    }

    pub fn verify(&self, expected: &PublicIdentity) -> Result<(), &'static str> {
        if self.authority_public_key != expected.authority_public_key
            || self.authority_fingerprint != expected.authority_fingerprint
        {
            return Err("BUILD_RECIPE_AUTHORITY_MISMATCH");
        }
        let bytes = base64url_decode(&self.signature).map_err(|_| "BUILD_RECIPE_TAMPERED")?;
        let signature_bytes: [u8; 64] = bytes.try_into().map_err(|_| "BUILD_RECIPE_TAMPERED")?;
        let signature = Ed25519Signature::from_bytes(&signature_bytes);
        let canonical = canonical_json(&self.payload).map_err(|_| "BUILD_RECIPE_TAMPERED")?;
        expected
            .verifying_key()
            .map_err(|_| "BUILD_RECIPE_AUTHORITY_MISMATCH")?
            .verify(&canonical, &signature)
            .map_err(|_| "BUILD_RECIPE_TAMPERED")
    }

    pub fn verify_for(
        &self,
        expected: &PublicIdentity,
        worker_id: Uuid,
        now: time::OffsetDateTime,
    ) -> Result<(), &'static str> {
        self.verify(expected)?;
        let issued = time::OffsetDateTime::parse(&self.payload.issued_at, &Rfc3339)
            .map_err(|_| "BUILD_RECIPE_TIME_INVALID")?;
        let expires = time::OffsetDateTime::parse(&self.payload.expires_at, &Rfc3339)
            .map_err(|_| "BUILD_RECIPE_TIME_INVALID")?;
        if self.payload.protocol != PROTOCOL_VERSION
            || self.payload.worker_id != worker_id
            || self.payload.claim_generation <= 0
            || self.payload.commit.len() != 40
            || !lowercase_hex(&self.payload.commit)
            || !lowercase_sha256(&self.payload.source_sha256)
            || issued >= expires
            || issued > now.saturating_add(time::Duration::minutes(5))
            || expires - issued > time::Duration::minutes(40)
            || now >= expires
            || self.payload.source_ticket.commit != self.payload.commit
            || self.payload.source_ticket.source_sha256 != self.payload.source_sha256
            || self.payload.source_ticket.expires_at != self.payload.expires_at
            || self.payload.artifact_ticket.expires_at != self.payload.expires_at
        {
            return Err(if now >= expires {
                "BUILD_RECIPE_EXPIRED"
            } else {
                "BUILD_RECIPE_BINDING_MISMATCH"
            });
        }
        Ok(())
    }

    pub fn digest(&self) -> Result<String, String> {
        canonical_json(self)
            .map(|bytes| sha256_hex(&bytes))
            .map_err(|error| error.to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildLease {
    pub claim_token: String,
    pub artifact_token: String,
    pub expires_at: String,
    pub heartbeat_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildClaim {
    pub recipe: SignedBuildRecipe,
    pub recipe_sha256: String,
    pub lease: BuildLease,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildTestFailure {
    pub test: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildDiagnostic {
    pub severity: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildArtifactEvidence {
    pub artifact_id: Uuid,
    pub kind: String,
    pub relative_path: String,
    pub sha256: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BuildResultEvidence {
    pub protocol: String,
    pub build_id: Uuid,
    pub worker_id: Uuid,
    pub claim_generation: i64,
    pub project_id: Uuid,
    pub commit: String,
    pub source_sha256: String,
    pub recipe_sha256: String,
    pub exit_state: String,
    pub started_at: String,
    pub completed_at: String,
    pub output: String,
    pub output_sha256: String,
    #[serde(default)]
    pub test_failures: Vec<BuildTestFailure>,
    #[serde(default)]
    pub diagnostics: Vec<BuildDiagnostic>,
    #[serde(default)]
    pub artifacts: Vec<BuildArtifactEvidence>,
}

impl BuildResultEvidence {
    pub fn validate_shape(&self) -> Result<(), &'static str> {
        if self.protocol != PROTOCOL_VERSION {
            return Err("BUILD_RESULT_PROTOCOL_UNSUPPORTED");
        }
        if !matches!(
            self.exit_state.as_str(),
            "succeeded" | "failed" | "cancelled"
        ) {
            return Err("BUILD_RESULT_INVALID");
        }
        if self.output.len() > MAX_BUILD_OUTPUT_BYTES
            || sha256_hex(self.output.as_bytes()) != self.output_sha256
        {
            return Err("BUILD_RESULT_HASH_MISMATCH");
        }
        if self.artifacts.len() > usize::from(MAX_ARTIFACTS)
            || self
                .artifacts
                .iter()
                .any(|artifact| artifact.size_bytes > MAX_ARTIFACT_BYTES)
            || self
                .artifacts
                .iter()
                .map(|artifact| artifact.size_bytes)
                .sum::<u64>()
                > MAX_ARTIFACT_TOTAL_BYTES
        {
            return Err("BUILD_ARTIFACT_LIMIT_EXCEEDED");
        }
        if self.claim_generation <= 0
            || self.test_failures.len() > MAX_TEST_FAILURES
            || self.diagnostics.len() > MAX_DIAGNOSTICS
        {
            return Err("BUILD_RESULT_INVALID");
        }
        if self.test_failures.iter().any(|failure| {
            failure.test.is_empty()
                || failure.test.len() > 1_000
                || failure.message.len() > 16_000
                || failure.file.as_ref().is_some_and(|file| file.len() > 4_096)
                || failure.line == Some(0)
        }) || self.diagnostics.iter().any(|diagnostic| {
            !matches!(diagnostic.severity.as_str(), "note" | "warning" | "error")
                || diagnostic.message.len() > 16_000
                || diagnostic
                    .file
                    .as_ref()
                    .is_some_and(|file| file.len() > 4_096)
                || diagnostic.line == Some(0)
                || diagnostic.column == Some(0)
        }) {
            return Err("BUILD_RESULT_INVALID");
        }
        if self.artifacts.iter().any(|artifact| {
            !safe_relative_path(&artifact.relative_path)
                || artifact.kind.is_empty()
                || artifact.kind.len() > 64
                || !matches!(
                    artifact.kind.as_str(),
                    "xcresult" | "screenshot" | "recording" | "archive" | "diagnostics"
                )
                || !lowercase_sha256(&artifact.sha256)
        }) {
            return Err("BUILD_ARTIFACT_INVALID");
        }
        let mut artifact_ids = std::collections::HashSet::new();
        if self
            .artifacts
            .iter()
            .any(|artifact| !artifact_ids.insert(artifact.artifact_id))
        {
            return Err("BUILD_ARTIFACT_INVALID");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SignedBuildResult {
    pub evidence: BuildResultEvidence,
    pub worker_signature: String,
}

impl SignedBuildResult {
    pub fn verify(&self, device_public_key_spki: &[u8]) -> Result<(), &'static str> {
        self.evidence.validate_shape()?;
        let verifying_key = VerifyingKey::from_public_key_der(device_public_key_spki)
            .map_err(|_| "BUILD_RESULT_SIGNATURE_INVALID")?;
        let signature_bytes = base64url_decode(&self.worker_signature)
            .map_err(|_| "BUILD_RESULT_SIGNATURE_INVALID")?;
        let signature = P256Signature::from_slice(&signature_bytes)
            .map_err(|_| "BUILD_RESULT_SIGNATURE_INVALID")?;
        let canonical =
            canonical_json(&self.evidence).map_err(|_| "BUILD_RESULT_SIGNATURE_INVALID")?;
        verifying_key
            .verify(&canonical, &signature)
            .map_err(|_| "BUILD_RESULT_SIGNATURE_INVALID")
    }
}

pub fn safe_relative_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 1024
        && !path.starts_with('/')
        && !path.contains('\0')
        && path
            .split('/')
            .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64 && lowercase_hex(value)
}

fn lowercase_hex(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

pub fn canonical_json<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_value(value).and_then(|value| serde_json::to_vec(&value))
}

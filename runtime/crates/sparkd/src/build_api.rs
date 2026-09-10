//! Expose durable build submission, worker claims and verified results through project-authorized routes.

use axum::body::Bytes;

use axum::extract::{Extension, Path, State};

use axum::http::StatusCode;

use axum::response::{IntoResponse, Json, Response};

use serde_json::{Value, json};

use uuid::Uuid;

use crate::auth::Principal;

use crate::build_protocol::{BuildArtifactEvidence, BuildRequirements, SignedBuildResult};

use crate::capability::Capability;

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::state::AppState;

/// Carry the claim secret proving the worker currently holds the job.
pub const HEADER_BUILD_CLAIM: &str = "x-spark-build-claim";

pub const HEADER_ARTIFACT_TOKEN: &str = "x-spark-artifact-token";

pub const HEADER_ARTIFACT_SHA256: &str = "x-spark-artifact-sha256";

pub const HEADER_ARTIFACT_KIND: &str = "x-spark-artifact-kind";

pub const HEADER_ARTIFACT_PATH: &str = "x-spark-artifact-path";

fn envelope(code: &str, message: &str, status: StatusCode) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": { "code": code, "message": message, "request_id": crate::route::current_request_id() }
        })),
    )
}

fn internal(detail: &str) -> (StatusCode, Json<Value>) {
    envelope("INTERNAL", detail, StatusCode::INTERNAL_SERVER_ERROR)
}

fn service_error(detail: &str) -> (StatusCode, Json<Value>) {
    if detail.contains("NOT_IMMUTABLE") {
        envelope(
            "BUILD_COMMIT_NOT_IMMUTABLE",
            "commit must be a 40-hex sha",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    } else if detail.contains("PROJECT_NOT_FOUND") || detail.contains("NOT_FOUND") {
        envelope(
            "PROJECT_NOT_FOUND",
            "no such project",
            StatusCode::NOT_FOUND,
        )
    } else if detail.contains("TIMEOUT") {
        envelope(
            "BUILD_TIMEOUT_OUT_OF_RANGE",
            "timeout must be 60–1800 seconds",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    } else if detail.contains("SOURCE_DIGEST") || detail.contains("REQUIREMENTS") {
        envelope(
            detail,
            "the source digest or build requirements are invalid",
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    } else {
        envelope("BUILD_REJECTED", detail, StatusCode::UNPROCESSABLE_ENTITY)
    }
}

fn header<'a>(headers: &'a axum::http::HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
}

#[cfg(test)]
#[path = "build_api/tests.rs"]
mod tests;

mod builds;
pub use builds::{
    SubmitBuildBody, claim_build, get_build, renew_claim, report_result, submit_build,
};

mod workers;
use workers::worker_for_device;
pub use workers::{WorkerRegistrationBody, heartbeat_worker, list_workers, register_worker};

mod artifacts;
pub use artifacts::{get_artifact, upload_artifact};

//! Start authorized loopback analysis as durable work whose result survives the calling intent process.

use axum::Json;
use axum::body::Bytes;
use axum::extract::{Extension, State};
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::analysis::{
    AnalysisBody, AnalysisRequest, AnalysisRuntime, AnalysisTargetBody, INVALID_INPUT_CODE,
    OPERATION_KIND,
};
use crate::auth::Principal;
use crate::capability::Capability;
use crate::idempotency::json_response;
use crate::state::AppState;

type ApiError = (StatusCode, Json<Value>);

fn error(code: &str, message: impl Into<String>, status: StatusCode) -> ApiError {
    (
        status,
        Json(json!({ "error": { "code": code, "message": message.into() } })),
    )
}

fn invalid(message: impl Into<String>) -> ApiError {
    error(
        INVALID_INPUT_CODE,
        message,
        StatusCode::UNPROCESSABLE_ENTITY,
    )
}

/// Reject mismatched node or cluster identities so changed routes cannot silently answer on the wrong Spark.
pub(crate) fn check_target_with_qualification(
    state: &AppState,
    target: Option<&AnalysisTargetBody>,
    qualified: bool,
) -> Result<Option<crate::cluster_inference::ClusterInferenceRoute>, ApiError> {
    let (identity, _available, _cluster) = crate::preview::target_and_cluster(state)
        .map_err(|error| crate::models::internal_envelope(&error))?;

    let explicit_cluster = target.and_then(|target| target.cluster_id.as_deref());
    if qualified && explicit_cluster.is_some() && explicit_cluster != identity.cluster_id.as_deref()
    {
        return Err(error(
            "TARGET_IDENTITY_MISMATCH",
            "The requested node or cluster is not this runtime target.",
            StatusCode::CONFLICT,
        ));
    }
    let requested_cluster = explicit_cluster.or(identity.cluster_id.as_deref());
    let route = crate::cluster_inference::cluster_inference_route(
        state,
        requested_cluster,
        None,
        false,
        qualified,
    )?;
    if let Some(requested) = target
        && requested
            .node_id
            .as_deref()
            .is_some_and(|node_id| node_id != identity.node_id.to_string())
    {
        return Err(error(
            "TARGET_IDENTITY_MISMATCH",
            "The requested node or cluster is not this runtime target.",
            StatusCode::CONFLICT,
        ));
    }
    let routed_cluster_id = route.as_ref().map(|route| route.cluster_id.to_string());
    if route.is_some() && identity.cluster_id != routed_cluster_id {
        return Err(error(
            "TARGET_IDENTITY_MISMATCH",
            "The requested node or cluster is not this runtime target.",
            StatusCode::CONFLICT,
        ));
    }
    Ok(route)
}

/// Accept durable analysis and return its operation with HTTP 202.
pub async fn start_analysis(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: crate::idempotency::IdempotencyRequest,
    body: Bytes,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    start_analysis_with_qualification(
        state,
        principal,
        idempotency,
        body,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )
    .await
}

pub(crate) async fn start_analysis_with_qualification(
    state: AppState,
    principal: Principal,
    idempotency: crate::idempotency::IdempotencyRequest,
    body: Bytes,
    qualified: bool,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("inference/analyses")
        .check()?;

    // Reject unknown JSON fields as part of request validation.
    let decoded: AnalysisBody =
        serde_json::from_slice(&body).map_err(|error| invalid(error.to_string()))?;
    let request = AnalysisRequest::validate(&decoded).map_err(invalid)?;
    let cluster_route =
        check_target_with_qualification(&state, decoded.target.as_ref(), qualified)?;
    if let Some(route) = &cluster_route {
        crate::cluster_inference::verify_cluster_route_health(route).await?;
    }

    let engine = state.engine.manager.clone();
    if cluster_route.is_none() && engine.is_none() {
        return Err(crate::engine::EngineError::NotLoaded.envelope());
    }
    let Some(database) = state.database.clone() else {
        return Err(crate::models::internal_envelope("no database"));
    };

    let _admission = state.idempotency.admission_guard();
    let outcome = {
        let mut conn = database.lock();
        state
            .idempotency
            .create_operation(
                &mut conn,
                &idempotency,
                &state.jobs,
                OPERATION_KIND,
                None,
                &request.redacted_input().to_string(),
            )
            .map_err(|error| error.envelope())?
    };
    if !outcome.created {
        return Ok(json_response(&outcome));
    }
    let operation_id = outcome
        .response
        .operation_id
        .expect("a created analysis operation has an id");

    let runtime = AnalysisRuntime {
        engine,
        jobs: state.jobs.clone(),
        database: database.clone(),
    };
    let model_id = cluster_route
        .as_ref()
        .map(|route| route.upstream.model_id.clone())
        .unwrap_or_else(|| request_model_id(&state));
    let recorder = crate::engine_api::UsageRecorder::new(&state, &principal, &model_id, None);
    if let Err(start_error) =
        crate::analysis::spawn(&runtime, operation_id, request, cluster_route, recorder)
    {
        // Persist refusal on the existing operation and replay record so retrying cannot start a second analysis.
        let (status, Json(envelope)) = start_error.envelope();
        let replacement = crate::idempotency::StoredResponse {
            status,
            body: envelope.clone(),
            operation_id: Some(operation_id),
        };
        let code = start_error.code();
        state
            .idempotency
            .replace_response(
                &mut database.lock(),
                &idempotency,
                &replacement,
                |transaction| state.jobs.fail(transaction, operation_id, &code),
            )
            .map_err(|error| error.envelope())?;
        return Err((status, Json(envelope)));
    }

    Ok(json_response(&outcome))
}

/// Attribute usage to the loaded model; spawn refuses empty model identity before recording usage.
fn request_model_id(state: &AppState) -> String {
    state
        .engine
        .manager
        .as_ref()
        .and_then(|manager| manager.view())
        .map(|view| view.model_id)
        .unwrap_or_default()
}

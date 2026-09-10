//! Authenticate and sanitize inference requests, admit the active instance, then stream only allowlisted loopback engine routes with internal credentials.

use std::sync::Arc;

use std::time::Duration;

use axum::Json;

use axum::body::{Body, Bytes};

use axum::extract::{Extension, State};

use axum::http::StatusCode;

use axum::http::header::CONTENT_TYPE;

use axum::response::Response;

use futures::{Stream, StreamExt};

use serde::Deserialize;

use serde_json::{Map, Value, json};

use spark_telemetry::{AdmissionDecision, PressureState};

use crate::auth::Principal;

use crate::capability::Capability;

use crate::cluster_inference::{
    InferenceRequestTicket, cluster_inference_route, verify_cluster_route_health,
};

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::preview::{
    PreviewBinding, PreviewConsequences, PreviewDraft, PreviewEvidence, PreviewMessage,
    PreviewRecipeIdentity, action_key, active_engine, target_and_cluster,
};

use crate::state::AppState;

fn err(code: &str, message: impl Into<String>, status: StatusCode) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({ "error": { "code": code, "message": message.into() } })),
    )
}

/// Report current engine state and performance.
pub async fn active_inference(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("inference/active")
        .check()?;
    if let Some(route) = cluster_inference_route(
        &state,
        None,
        None,
        true,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )? {
        verify_cluster_route_health(&route).await?;
        return Ok(Json(json!({
            "state": "ready",
            "model_id": route.upstream.model_id,
            "profile_id": route.profile_id,
            "context_length": route.max_model_length,
            "active_requests": 0,
            "queue_depth": 0,
            "tokens_per_second": null,
            "time_to_first_token_ms": null,
            "cluster_id": route.cluster_id,
            "launch_id": route.launch_id,
        })));
    }
    let Some(manager) = &state.engine.manager else {
        return Err(crate::models::internal_envelope("engine unavailable"));
    };
    Ok(Json(manager.inference_active()))
}

/// List models exposed by the active engine through the OpenAI-compatible API.
pub async fn openai_models(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("v1/models")
        .check()?;
    // A guest is shown the models the owner shared, never the engine's own catalogue.
    if let Some(allowed) = crate::guest::allowed_models(&state, &principal) {
        let data: Vec<Value> = allowed
            .into_iter()
            .map(|id| json!({ "id": id, "object": "model" }))
            .collect();
        return Ok(Json(json!({ "object": "list", "data": data })));
    }
    if let Some(route) = cluster_inference_route(
        &state,
        None,
        None,
        true,
        crate::cluster_coordination::CLUSTER_INFERENCE_QUALIFIED,
    )? {
        verify_cluster_route_health(&route).await?;
        return Ok(Json(json!({
            "object": "list",
            "data": [{ "id": route.upstream.served_name, "object": "model" }]
        })));
    }
    let Some(manager) = &state.engine.manager else {
        return Err(crate::models::internal_envelope("engine unavailable"));
    };
    let Some(view) = manager.view() else {
        return Err(err(
            "MODEL_NOT_LOADED",
            "no active engine",
            StatusCode::NOT_FOUND,
        ));
    };
    Ok(Json(json!({
        "object": "list",
        "data": [{ "id": view.served_name, "object": "model" }]
    })))
}

#[cfg(test)]
#[path = "engine_api/audit_tests.rs"]
mod audit_tests;

mod openai_requests;
pub(crate) use openai_requests::anthropic_messages;
use openai_requests::parse_openai;
pub use openai_requests::{ChatRequest, chat_completions, openai_responses, parse_chat};

mod usage_stream;
pub use usage_stream::UsageScanner;
use usage_stream::UsageTee;
pub(crate) use usage_stream::{UsageRecorder, UsageTotals};

mod load_preview;
pub(crate) use load_preview::load_preview_draft;
pub use load_preview::{LoadModelBody, LoadModelPreviewBody, LoadTargetBody};

mod stop_preview;
pub use stop_preview::{
    StopModelBody, StopModelPreviewBody, preview_unload_inference, unload_inference,
};

mod load_routes;
pub use load_routes::{load_inference, preview_load_inference};

mod openai_proxy;
use openai_proxy::proxy_openai_with_qualification;

#[cfg(test)]
pub(crate) use openai_requests::chat_completions_with_qualification;

mod web_tools_gateway;
pub use web_tools_gateway::{harness_completion, wants_web_tools};

//! Observe workloads read-only with durable ownership and advisory recognition; exact adoption is a separate reviewed transaction.

use axum::Extension;

use axum::extract::State;

use axum::http::StatusCode;

use axum::response::Json;

use futures::StreamExt;

use serde_json::{Value, json};

use spark_privd::PrivilegedOperation;

use spark_privd::workloads::{
    MANAGED_ENGINE_PREFIX, MANAGED_PROJECT_PREFIX, ObservedContainer, ObservedWorkloads,
};

use crate::auth::Principal;

use crate::capability::Capability;

use crate::state::AppState;

/// Bound inventory observation to three seconds so a stalled runtime is reported unavailable.
const OBSERVATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Workloads carried in one response, from the contract's `maxItems`.
const MAX_REPORTED_WORKLOADS: usize = 64;

/// Probe at most four ports per recognized external engine so published ranges cannot induce a host port scan.
const MAX_MODEL_PROBE_PORTS: usize = 4;

/// Bound all model probes per inventory request to four, limiting refused-endpoint latency independently of container count.
const MAX_MODEL_PROBES_PER_INVENTORY: usize = 4;

/// Maximum OpenAI model-list response accepted from an external service.
const MAX_MODEL_PROBE_BYTES: usize = 64 * 1024;

/// Repeat at most sixteen unambiguous aliases; larger or malformed lists are unavailable rather than silently truncated.
const MAX_SERVED_MODELS: usize = 16;

/// Publish the same adoption support capability in inventory and capability documents.
pub const ADOPTION_SUPPORTED: bool = true;

/// Require diagnostics.read for host container images and ports; node.read alone does not authorize workload detail.
pub async fn list_workloads(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::DiagnosticsRead)
        .resource("/api/v1/workloads")
        .check()?;

    let observed_at = state.clock.now_rfc3339();
    let adoption_supported = ADOPTION_SUPPORTED
        && state.privileged.is_some()
        && state.engine.manager.is_some()
        && state.models.is_some();
    let Some(privileged) = state.privileged.clone() else {
        return Ok(Json(unavailable(
            &observed_at,
            "this runtime has no privileged boundary, so host workloads cannot be observed",
            adoption_supported,
        )));
    };

    let response = tokio::task::spawn_blocking(move || {
        privileged.call_bounded(
            PrivilegedOperation::InventoryWorkloads {
                request_id: uuid::Uuid::new_v4(),
            },
            OBSERVATION_TIMEOUT,
        )
    })
    .await;

    // Return a stable secret-free failure reason while keeping helper paths and raw diagnostics in node logs.
    let response = match response {
        Err(error) => {
            tracing::error!(%error, "workload observation task failed");
            return Ok(Json(unavailable(
                &observed_at,
                "the container runtime could not be inspected",
                adoption_supported,
            )));
        }
        Ok(Err(error)) => {
            tracing::warn!(%error, "workload observation boundary unavailable");
            return Ok(Json(unavailable(
                &observed_at,
                "the container runtime could not be inspected",
                adoption_supported,
            )));
        }
        Ok(Ok(response)) => response,
    };

    if !response.accepted {
        tracing::warn!(code = %response.code, "workload observation refused");
        return Ok(Json(unavailable(
            &observed_at,
            "the container runtime could not be inspected",
            adoption_supported,
        )));
    }

    let observed: ObservedWorkloads = match serde_json::from_value(response.details) {
        Ok(observed) => observed,
        Err(error) => {
            // An undecodable helper response cannot prove the host is empty.
            tracing::error!(%error, "workload observation could not be decoded");
            return Ok(Json(unavailable(
                &observed_at,
                "the container runtime could not be inspected",
                adoption_supported,
            )));
        }
    };

    // Report unreadable container output as unavailable rather than an empty idle host.
    if observed.containers.is_empty() && observed.unreadable_lines > 0 {
        tracing::warn!(
            unreadable_lines = observed.unreadable_lines,
            "workload observation produced no readable rows"
        );
        return Ok(Json(unavailable(
            &observed_at,
            "the container runtime could not be inspected",
            adoption_supported,
        )));
    }

    // Determine ownership from daemon state; a host container name alone proves nothing.
    let database = state.database.clone();
    let managed = tokio::task::spawn_blocking(move || {
        database.map_or_else(ManagedIds::default, |database| managed_ids(&database))
    })
    .await
    .unwrap_or_else(|error| {
        // Without durable records, classify workloads external and grant no lifecycle authority.
        tracing::error!(%error, "workload ownership lookup failed");
        ManagedIds::default()
    });

    let mut workloads = Vec::new();
    let mut model_probe_budget = MAX_MODEL_PROBES_PER_INVENTORY;
    for container in observed.containers.iter().take(MAX_REPORTED_WORKLOADS) {
        let classification = classify(container, &managed);
        let configuration =
            observe_external_configuration(container, classification, &mut model_probe_budget)
                .await;
        workloads.push(present(container, classification, configuration));
    }
    Ok(Json(json!({
        "observed_at": observed_at,
        "available": true,
        "adoption_supported": adoption_supported,
        // Mark inventory incomplete for both size truncation and unreadable host rows.
        "truncated": observed.truncated
            || observed.unreadable_lines > 0
            || observed.containers.len() > MAX_REPORTED_WORKLOADS,
        "workloads": workloads,
    })))
}

/// Return available:false when observation fails so an empty list cannot claim the Spark is idle.
fn unavailable(observed_at: &str, reason: &str, adoption_supported: bool) -> Value {
    json!({
        "observed_at": observed_at,
        "available": false,
        "unavailable_reason": reason,
        "adoption_supported": adoption_supported,
        "truncated": false,
        "workloads": [],
    })
}

#[cfg(test)]
#[path = "workload_api/tests.rs"]
mod tests;

mod classification;
use classification::{Classification, ManagedIds, classify, managed_ids, present};

mod external_inference;
use external_inference::{ExternalConfiguration, observe_external_configuration};
pub(crate) use external_inference::{ExternalInferenceGuard, external_inference_guard};

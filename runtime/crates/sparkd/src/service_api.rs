//! Derive optional-service mutations from verified recipes before typed privileged dispatch.

use axum::body::{Body, to_bytes};

use axum::extract::ws::{Message as AxumMessage, WebSocket};

use axum::extract::{Extension, FromRequestParts, Request, State, WebSocketUpgrade};

use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};

use axum::middleware::{self, Next};

use axum::response::{IntoResponse, Response};

use axum::routing::{any, get, post};

use axum::{Json, Router};

use base64::Engine as _;

use rand::RngCore as _;

use serde::Deserialize;

use serde_json::{Value, json};

use sha2::{Digest as _, Sha256};

use spark_models::service_recipe::{ServiceRecipe, load_open_webui_recipe};

use spark_privd::protocol::{PrivilegedOperation, SecretString};

use tokio_tungstenite::tungstenite::Message as TungsteniteMessage;

use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::appliance_api::enqueue_operation;

use crate::auth::{AuthenticatedRequest, Principal};

use crate::capability::Capability;

use crate::idempotency::IdempotencyRequest;

use crate::state::AppState;

const SERVICE_ID: &str = "open-webui";

fn open_webui_upstream(state: &AppState) -> String {
    format!(
        "http://127.0.0.1:{}",
        state
            .open_webui_upstream_port
            .load(std::sync::atomic::Ordering::SeqCst)
    )
}

pub async fn restore_open_webui_route(state: &AppState) {
    let _ = open_webui_status_snapshot(state).await;
}

const OPEN_WEBUI_PROXY_BODY_LIMIT: usize = 32 * 1024 * 1024;

fn envelope(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

pub fn verified_open_webui_recipe(
    state: &AppState,
) -> Result<ServiceRecipe, spark_models::service_recipe::ServiceRecipeError> {
    load_open_webui_recipe(
        state.optional_service_recipe_path.as_ref(),
        state.optional_service_root_key_path.as_ref(),
    )
}

fn recipe(state: &AppState) -> Result<ServiceRecipe, (StatusCode, Json<Value>)> {
    verified_open_webui_recipe(state).map_err(|error| {
        tracing::error!(%error, "bundled Open WebUI recipe failed verification");
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "SERVICE_RECIPE_UNAVAILABLE",
            "the signed Open WebUI recipe could not be verified",
        )
    })
}

fn privileged(
    state: &AppState,
) -> Result<crate::privd::PrivilegedClient, (StatusCode, Json<Value>)> {
    if !state
        .optional_services_available
        .load(std::sync::atomic::Ordering::SeqCst)
    {
        return Err(envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional service listeners are unavailable",
        ));
    }
    state.privileged.clone().ok_or_else(|| {
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICES_UNAVAILABLE",
            "optional services require the privileged container boundary",
        )
    })
}

fn require_service_read(
    state: &AppState,
    principal: &Principal,
) -> Result<(), (StatusCode, Json<Value>)> {
    state
        .require(principal, Capability::NodeRead)
        .resource(SERVICE_ID)
        .check()
}

pub async fn list_services(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_service_read(&state, &principal)?;
    let status = open_webui_status_snapshot(&state).await?;
    Ok(Json(json!({ "services": [status] })))
}

pub async fn open_webui_status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_service_read(&state, &principal)?;
    open_webui_status_snapshot(&state).await.map(Json)
}

async fn open_webui_status_snapshot(state: &AppState) -> Result<Value, (StatusCode, Json<Value>)> {
    let result = checked_open_webui_status(state).await;
    if result.is_err() {
        state
            .open_webui_upstream_port
            .store(0, std::sync::atomic::Ordering::SeqCst);
    }
    result
}

async fn checked_open_webui_status(state: &AppState) -> Result<Value, (StatusCode, Json<Value>)> {
    let recipe = recipe(state)?;
    let client = privileged(state)?;
    let response = tokio::task::spawn_blocking(move || {
        client.call_bounded(
            PrivilegedOperation::OpenWebUiStatus {
                request_id: uuid::Uuid::new_v4(),
            },
            std::time::Duration::from_secs(3),
        )
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "Open WebUI status task failed");
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICE_STATUS_UNAVAILABLE",
            "Open WebUI status could not be checked",
        )
    })?
    .map_err(|error| {
        tracing::warn!(%error, "Open WebUI status boundary unavailable");
        envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPTIONAL_SERVICE_STATUS_UNAVAILABLE",
            "Open WebUI status could not be checked",
        )
    })?;
    if !response.accepted {
        return Err(envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            &response.code.to_ascii_uppercase(),
            "Open WebUI status could not be checked",
        ));
    }
    let adopted = response.details["adopted"].as_bool().unwrap_or(false);
    let port = response.details["port"]
        .as_u64()
        .and_then(|p| u16::try_from(p).ok())
        .unwrap_or(18080);
    if !spark_privd::protocol::valid_open_webui_port(port) {
        return Err(envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "OPEN_WEBUI_PORT_INVALID",
            "Saved Open WebUI port is invalid",
        ));
    }
    let installed = response.details["installed"].as_bool().unwrap_or(false);
    let running = response.details["running"].as_bool().unwrap_or(false);
    let ownership_verified = response.details["ownership_verified"]
        .as_bool()
        .unwrap_or(false);
    state.open_webui_upstream_port.store(
        if installed && ownership_verified {
            port
        } else {
            0
        },
        std::sync::atomic::Ordering::SeqCst,
    );
    let container_healthy = response.details["healthy"].as_bool().unwrap_or(false);
    let gateway_state = state
        .database
        .as_ref()
        .and_then(|database| {
            database
                .lock()
                .query_row(
                    "SELECT enabled, pending_install FROM optional_services WHERE service_id = ?1",
                    [SERVICE_ID],
                    |row| Ok((row.get::<_, bool>(0)?, row.get::<_, bool>(1)?)),
                )
                .ok()
        })
        .unwrap_or((false, false));
    let (mut gateway_configured, pending_install) = gateway_state;
    let gateway_reachable = response.details["gateway_healthy"]
        .as_bool()
        .unwrap_or(false);
    if (!installed || !ownership_verified) && gateway_configured {
        gateway_configured = state
            .database
            .as_ref()
            .is_none_or(|database| disable_gateway(database.as_ref()).is_err());
        if !gateway_configured {
            tracing::warn!(
                service_id = SERVICE_ID,
                "reconciled Open WebUI state after its container was removed"
            );
        }
    }
    if container_healthy && gateway_reachable && pending_install && !gateway_configured {
        gateway_configured = state.database.as_ref().is_some_and(|database| {
            database
                .lock()
                .execute(
                    "UPDATE optional_services
                        SET enabled = 1, pending_install = 0,
                            updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                      WHERE service_id = ?1 AND pending_install = 1",
                    [SERVICE_ID],
                )
                .is_ok_and(|changed| changed == 1)
        });
        if gateway_configured {
            tracing::warn!(
                service_id = SERVICE_ID,
                "reconciled Open WebUI after an interrupted install"
            );
        }
    }
    let healthy =
        ownership_verified && container_healthy && gateway_configured && gateway_reachable;
    let recovery = if !ownership_verified && installed {
        response.details.get("recovery").cloned().unwrap_or(json!({
            "code": "OPEN_WEBUI_OWNERSHIP_UNVERIFIED",
            "action": "inspect_locally_preserve_data"
        }))
    } else if container_healthy && !gateway_configured {
        json!({
            "code": "OPEN_WEBUI_GATEWAY_STATE_MISSING",
            "action": if adopted { "disconnect_and_reconnect_preserving_data" } else { "remove_with_data_erasure_and_reinstall" }
        })
    } else if container_healthy && !gateway_reachable {
        json!({
            "code": "OPEN_WEBUI_GATEWAY_UNREACHABLE",
            "action": "restart_spark_runtime_and_retry"
        })
    } else {
        response
            .details
            .get("recovery")
            .cloned()
            .unwrap_or(Value::Null)
    };
    let installed_image = response.details["image_digest"].as_str();
    let update_available = !adopted
        && installed
        && installed_image.is_some_and(|image| image != recipe.container.image);
    Ok(json!({
        "id": SERVICE_ID,
        "display_name": recipe.metadata.display_name,
        "state": if healthy { "healthy" } else if container_healthy { "recovering" } else if running { "starting" } else if installed { "stopped" } else { "not_installed" },
        "installed": installed,
        "adopted": adopted,
        "service_port": port,
        "ownership_verified": ownership_verified,
        "repair_available": !adopted && ownership_verified && (gateway_configured || pending_install) && gateway_reachable
            && response.details["repair_available"].as_bool().unwrap_or(false),
        "running": running,
        "healthy": healthy,
        "installed_image_digest": installed_image,
        "available_revision": recipe.metadata.revision,
        "available_version": recipe.container.version,
        "update_available": update_available,
        "access_path": healthy.then_some("/services/open-webui/"),
        "access_port": state.config.listen.port().checked_add(1),
        "access_tls": state.config.tls,
        "inference_gateway": {
            "scopes": if adopted { Vec::<String>::new() } else { recipe.gateway.scopes },
            "healthy": !adopted && healthy,
            "port": spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT,
            "loopback_only": true,
        },
        "recovery": recovery,
    }))
}

pub async fn open_webui_access(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_service_read(&state, &principal)?;
    let status = open_webui_status_snapshot(&state).await?;
    if status["healthy"] != true {
        return Err(envelope(
            StatusCode::CONFLICT,
            "OPEN_WEBUI_NOT_READY",
            "Open WebUI must be healthy before it can be opened",
        ));
    }
    Ok(Json(json!({ "access_path": "/services/open-webui/" })))
}

mod gateway;
pub use gateway::{access_proxy_router, inference_gateway_router, lan_scoped, open_webui_redirect};
use gateway::{clear_pending_install, disable_gateway, set_gateway_state, sha256_hex};

mod installation;
pub use installation::{InstallOpenWebUiRequest, install_open_webui};

mod maintenance;
pub use maintenance::{
    RemoveOpenWebUiRequest, remove_open_webui, repair_open_webui, update_open_webui,
};

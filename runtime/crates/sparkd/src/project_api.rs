//! Expose project lifecycle, revision-conditional files, container PTYs and authenticated registered-port previews.

use axum::Json;

use axum::body::Bytes;

use axum::extract::{Extension, Path as RoutePath, State, WebSocketUpgrade};

use axum::http::StatusCode;

use axum::response::{IntoResponse, Response};

use serde_json::{Value, json};

use crate::auth::Principal;

use crate::capability::{
    Capability, Presence, ProjectPermission, Request, ResourceScope, Role, evaluate,
};

use crate::idempotency::{IdempotencyRequest, StoredResponse, json_response};

use crate::state::AppState;

fn internal_envelope(message: &str) -> (StatusCode, Json<Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": { "code": "INTERNAL_ERROR", "message": message }
        })),
    )
}

fn not_found() -> (StatusCode, Json<Value>) {
    (
        StatusCode::NOT_FOUND,
        Json(json!({ "error": { "code": "PROJECT_NOT_FOUND", "message": "PROJECT_NOT_FOUND" } })),
    )
}

fn project(
    project_id: &uuid::Uuid,
    state: &AppState,
) -> Result<crate::project::ProjectView, (StatusCode, Json<Value>)> {
    let Some(manager) = &state.projects.manager else {
        return Err(internal_envelope("project service unavailable"));
    };
    match manager.get(project_id) {
        Ok(view) => Ok(view),
        Err(_) => Err(not_found()),
    }
}

mod projects;
pub use projects::{CreateProjectBody, create_project, delete_project, get_project, list_projects};

mod files;
pub use files::{list_files, preview_asset, read_file, save_file};

mod codex_cache;
mod development;
pub mod development_prepare;
mod omp_cache;
pub use development_prepare::{development_preparation, prepare_development};
mod terminals;
pub use terminals::{attach_terminal, close_terminal, create_terminal, terminal_state};

mod terminal_transport;
use terminal_transport::{TerminalAuthorization, drive_terminal};

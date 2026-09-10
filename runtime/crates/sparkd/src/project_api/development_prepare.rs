//! Pull the development image and cache the coding agent as soon as the owner turns Engineering Mode on, so the first workspace opens without a wait.
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use axum::Json;
use axum::extract::{Extension, State};
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::auth::Principal;
use crate::capability::Capability;
use crate::state::AppState;

/// Written once the owner has asked, so every later boot prepares the current image and pin unprompted.
const MARKER: &str = "harness-cache/development-requested";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Preparing,
    Ready,
    Failed,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Preparing => "preparing",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub phase: Phase,
    pub image_ready: bool,
    pub harness_ready: bool,
    pub detail: Option<String>,
}

impl Status {
    pub fn to_json(&self) -> Value {
        json!({
            "status": self.phase.as_str(),
            "image_ready": self.image_ready,
            "harness_ready": self.harness_ready,
            "detail": self.detail,
        })
    }
}

/// Caches the harness pin on the host; injectable so tests never reach GitHub.
pub type HarnessWarmer =
    Arc<dyn Fn(&std::path::Path) -> std::result::Result<bool, String> + Send + Sync>;

/// One preparation at a time per runtime; its status outlives the request that started it.
pub struct DevelopmentPreparation {
    status: parking_lot::Mutex<Status>,
    running: AtomicBool,
    warm_harness: HarnessWarmer,
}

impl Default for DevelopmentPreparation {
    fn default() -> Self {
        Self::with_harness_warmer(Arc::new(super::omp_cache::warm))
    }
}

impl DevelopmentPreparation {
    pub fn with_harness_warmer(warm_harness: HarnessWarmer) -> Self {
        Self {
            status: parking_lot::Mutex::new(Status {
                phase: Phase::Idle,
                image_ready: false,
                harness_ready: false,
                detail: None,
            }),
            running: AtomicBool::new(false),
            warm_harness,
        }
    }

    /// The last outcome; before any run, only the harness cache can be read from disk.
    pub fn status(&self, state: &AppState) -> Status {
        let mut status = self.status.lock().clone();
        if status.phase == Phase::Idle {
            status.harness_ready = super::omp_cache::is_cached(&state.config.data_dir);
        }
        status
    }

    /// Start a run unless one is in flight; either way the caller learns the current status.
    pub fn start(self: &Arc<Self>, state: AppState) -> Status {
        if self.running.swap(true, Ordering::SeqCst) {
            return self.status.lock().clone();
        }
        let status = Status {
            phase: Phase::Preparing,
            image_ready: false,
            harness_ready: super::omp_cache::is_cached(&state.config.data_dir),
            detail: None,
        };
        *self.status.lock() = status.clone();
        let this = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let outcome = this.run(&state);
            if outcome.phase == Phase::Failed {
                tracing::warn!(detail = ?outcome.detail, "development preparation incomplete");
            } else {
                tracing::info!("development image and coding agent are ready");
            }
            *this.status.lock() = outcome;
            this.running.store(false, Ordering::SeqCst);
        });
        status
    }

    fn run(&self, state: &AppState) -> Status {
        let data_dir = &state.config.data_dir;
        if let Err(error) = crate::beneath::create_dir_all_beneath(data_dir, "harness-cache")
            .and_then(|_| crate::beneath::write_beneath(data_dir, MARKER, b"requested\n"))
        {
            tracing::warn!(%error, "development preparation marker could not be written");
        }
        let mut detail = Vec::new();
        let image_ready = match state.privileged.as_ref() {
            Some(privileged) => match crate::download_api::ensure_engine_image_ready(
                privileged,
                spark_core::DEVELOPMENT_IMAGE,
            ) {
                Ok(()) => true,
                Err(error) => {
                    detail.push(format!("development image: {error}"));
                    false
                }
            },
            None => {
                detail.push("development image: the privileged helper is unavailable".to_owned());
                false
            }
        };
        let harness_ready = match (self.warm_harness)(data_dir) {
            Ok(_) => true,
            Err(error) => {
                detail.push(error);
                false
            }
        };
        Status {
            phase: if image_ready && harness_ready {
                Phase::Ready
            } else {
                Phase::Failed
            },
            image_ready,
            harness_ready,
            detail: (!detail.is_empty()).then(|| detail.join("; ")),
        }
    }
}

/// Owners who asked once get the current runtime's image and pin prepared at every boot.
pub fn spawn_on_boot(state: AppState) {
    if state.projects.manager.is_none()
        || crate::beneath::metadata_beneath(&state.config.data_dir, MARKER).is_err()
    {
        return;
    }
    let preparation = Arc::clone(&state.projects.preparation);
    let _ = preparation.start(state);
}

fn unavailable() -> (StatusCode, Json<Value>) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({ "error": {
            "code": "DEVELOPMENT_UNAVAILABLE",
            "message": "This Spark's runtime does not host development workspaces."
        }})),
    )
}

/// Begin (or report) preparation; no user presence is needed because nothing owner-visible changes.
pub async fn prepare_development(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectCreate)
        .resource("projects")
        .check()?;
    if state.projects.manager.is_none() {
        return Err(unavailable());
    }
    let preparation = Arc::clone(&state.projects.preparation);
    let status = preparation.start(state.clone());
    Ok((StatusCode::ACCEPTED, Json(status.to_json())))
}

pub async fn development_preparation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, Capability::ProjectList)
        .resource("projects")
        .check()?;
    if state.projects.manager.is_none() {
        return Err(unavailable());
    }
    Ok((
        StatusCode::OK,
        Json(state.projects.preparation.status(&state).to_json()),
    ))
}

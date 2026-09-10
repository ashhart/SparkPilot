//! The owner's console for automations: what runs, when, with which model, and whether it may read the web.

use axum::Json;
use axum::extract::{Extension, Path as AxumPath, State};
use axum::http::{HeaderMap, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::auth::{AuthenticatedRequest, Principal};
use crate::authz::Denial;
use crate::automations::scheduler::{self, RUN_KIND};
use crate::automations::store::{self, Automation, AutomationRun, MAX_AUTOMATIONS};
use crate::capability::Capability;
use crate::idempotency::IdempotencyRequest;
use crate::state::AppState;
use crate::web_tools::backend::{SearchBackend, WebAccessSettings};
use crate::web_tools::policy::WebAccessPolicy;
use crate::web_tools::session;

/// The provider label a search key is stored under.
pub const BRAVE_PROVIDER: &str = "brave-search";
const AUTOMATIONS_ROUTE: &str = "/api/v1/automations";

pub mod runs;
pub mod web_answer;
pub mod web_settings;

fn envelope(status: StatusCode, code: &str, message: &str) -> Denial {
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

fn unavailable() -> Denial {
    envelope(
        StatusCode::INTERNAL_SERVER_ERROR,
        "INTERNAL",
        "the automations database is unavailable",
    )
}

/// One automation as the app reads it, with the state of its most recent run.
fn presented(conn: &rusqlite::Connection, automation: &Automation) -> Value {
    let last = store::last_run(conn, automation.id).ok().flatten();
    json!({
        "id": automation.id,
        "name": automation.name,
        "instructions": automation.instructions,
        "schedule": {
            "preset": automation.schedule_preset,
            "expression": automation.schedule_expression,
            "timezone": automation.timezone,
        },
        "model_id": automation.model_id,
        "profile_id": automation.profile_id,
        "web_access": automation.web_access,
        "delivery": {"notify": automation.notify},
        "enabled": automation.enabled,
        "next_run_at": automation.next_run_at,
        "last_run_at": last.as_ref().map(|(at, _)| *at),
        "last_run_state": last
            .as_ref()
            .map(|(_, state)| state.as_str())
            .unwrap_or("none"),
        "created_at": automation.created_at,
        "updated_at": automation.updated_at,
    })
}

fn listing(state: &AppState) -> Result<Value, Denial> {
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let conn = database.lock();
    let items = store::list(&conn)
        .map_err(|error| {
            envelope(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                &error.to_string(),
            )
        })?
        .iter()
        .map(|automation| presented(&conn, automation))
        .collect::<Vec<_>>();
    Ok(json!({
        "items": items,
        "max_automations": MAX_AUTOMATIONS,
        "observed_at": state.clock.now().unix_timestamp(),
    }))
}

/// What the owner may set when creating one.
#[derive(Debug, Clone, Deserialize)]
pub struct AutomationRequest {
    pub name: String,
    pub instructions: String,
    pub schedule: ScheduleRequest,
    pub model_id: String,
    #[serde(default)]
    pub profile_id: Option<String>,
    #[serde(default)]
    pub web_access: bool,
    #[serde(default)]
    pub delivery: Option<DeliveryRequest>,
    #[serde(default = "enabled_by_default")]
    pub enabled: bool,
}

fn enabled_by_default() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleRequest {
    pub preset: String,
    pub expression: String,
    pub timezone: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct DeliveryRequest {
    pub notify: bool,
}

/// Only the supplied fields change.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct AutomationUpdateRequest {
    pub name: Option<String>,
    pub instructions: Option<String>,
    pub schedule: Option<ScheduleRequest>,
    pub model_id: Option<String>,
    pub profile_id: Option<Option<String>>,
    pub web_access: Option<bool>,
    pub delivery: Option<DeliveryRequest>,
    pub enabled: Option<bool>,
}

fn validate(name: &str, instructions: &str, schedule: &ScheduleRequest) -> Result<(), Denial> {
    if name.trim().is_empty() || name.chars().count() > 80 {
        return Err(envelope(
            StatusCode::BAD_REQUEST,
            "AUTOMATION_NAME_INVALID",
            "an automation needs a name of up to eighty characters",
        ));
    }
    if instructions.trim().is_empty() || instructions.chars().count() > 2_000 {
        return Err(envelope(
            StatusCode::BAD_REQUEST,
            "AUTOMATION_INSTRUCTIONS_INVALID",
            "an automation needs instructions of up to two thousand characters",
        ));
    }
    if !matches!(
        schedule.preset.as_str(),
        "daily" | "weekdays" | "every_n_hours" | "weekly" | "custom"
    ) {
        return Err(envelope(
            StatusCode::BAD_REQUEST,
            "AUTOMATION_SCHEDULE_INVALID",
            "that is not a schedule shape this Spark understands",
        ));
    }
    Ok(())
}

/// Compute the first slot, refusing an expression or a zone the Spark cannot read.
fn first_slot(state: &AppState, schedule: &ScheduleRequest) -> Result<Option<i64>, Denial> {
    let now = state.clock.now().unix_timestamp();
    store::next_slot(&schedule.expression, &schedule.timezone, now).map_err(|code| {
        let message = match code {
            "AUTOMATION_TIMEZONE_UNKNOWN" => {
                "this Spark does not have that time zone, so the automation was not saved"
            }
            _ => "that schedule is not one this Spark can read, so the automation was not saved",
        };
        envelope(StatusCode::BAD_REQUEST, code, message)
    })
}

/// Turning web access on changes what the appliance sends to third parties, so it needs presence.
fn require_presence_for_web(
    state: &AppState,
    principal: &Principal,
    authenticated: &AuthenticatedRequest,
    headers: &HeaderMap,
) -> Result<(), Denial> {
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let key = {
        let conn = database.lock();
        crate::store::load_presence_key_by_device_id(&conn, &principal.device_id)
            .map_err(|_| unavailable())?
    };
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        key.as_deref(),
        authenticated,
        state.clock.now(),
    )
    .map_err(|failure| {
        envelope(
            StatusCode::FORBIDDEN,
            failure.code(),
            "turning web access on for an automation needs a fresh presence check",
        )
    })
}

pub async fn list_automations(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::AutomationRead)
        .resource(AUTOMATIONS_ROUTE)
        .check()?;
    Ok(Json(listing(&state)?))
}

pub async fn create_automation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    Json(request): Json<AutomationRequest>,
) -> Result<(StatusCode, Json<Value>), Denial> {
    state
        .require(&principal, Capability::AutomationManage)
        .resource(AUTOMATIONS_ROUTE)
        .details(json!({"web_access": request.web_access}))
        .check()?;
    validate(&request.name, &request.instructions, &request.schedule)?;
    if request.web_access {
        require_presence_for_web(&state, &principal, &authenticated, &headers)?;
    }
    let next_run_at = first_slot(&state, &request.schedule)?;
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let now = state.clock.now().unix_timestamp();
    let conn = database.lock();
    if store::count(&conn).map_err(|_| unavailable())? >= MAX_AUTOMATIONS {
        return Err(envelope(
            StatusCode::CONFLICT,
            "AUTOMATION_LIMIT_REACHED",
            "this Spark already holds as many automations as it keeps",
        ));
    }
    let draft = Automation {
        id: Uuid::new_v4(),
        owner_device_id: principal.device_id,
        name: request.name.trim().to_owned(),
        instructions: request.instructions.trim().to_owned(),
        schedule_preset: request.schedule.preset.clone(),
        schedule_expression: request.schedule.expression.clone(),
        timezone: request.schedule.timezone.clone(),
        model_id: request.model_id.clone(),
        profile_id: request.profile_id.clone(),
        web_access: request.web_access,
        notify: request
            .delivery
            .map(|delivery| delivery.notify)
            .unwrap_or(true),
        enabled: request.enabled,
        next_run_at,
        created_at: now,
        updated_at: now,
    };
    let stored = store::insert(
        &conn,
        state.identity.node_id(),
        principal.device_id,
        &draft,
        next_run_at,
        now,
    )
    .map_err(|error| {
        envelope(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            &error.to_string(),
        )
    })?;
    let body = presented(&conn, &stored);
    drop(conn);
    state.automations.wake.notify_one();
    Ok((StatusCode::CREATED, Json(body)))
}

pub async fn update_automation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    AxumPath(id): AxumPath<Uuid>,
    headers: HeaderMap,
    Json(request): Json<AutomationUpdateRequest>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::AutomationManage)
        .resource(AUTOMATIONS_ROUTE)
        .details(json!({"automation_id": id}))
        .check()?;
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let current = {
        let conn = database.lock();
        store::get(&conn, id).map_err(|_| unavailable())?
    };
    let Some(mut updated) = current else {
        return Err(envelope(
            StatusCode::NOT_FOUND,
            "AUTOMATION_NOT_FOUND",
            "this Spark has no automation with that id",
        ));
    };
    if request.web_access == Some(true) && !updated.web_access {
        require_presence_for_web(&state, &principal, &authenticated, &headers)?;
    }
    if let Some(name) = request.name {
        updated.name = name.trim().to_owned();
    }
    if let Some(instructions) = request.instructions {
        updated.instructions = instructions.trim().to_owned();
    }
    if let Some(model_id) = request.model_id {
        updated.model_id = model_id;
    }
    if let Some(profile_id) = request.profile_id {
        updated.profile_id = profile_id;
    }
    if let Some(web_access) = request.web_access {
        updated.web_access = web_access;
    }
    if let Some(delivery) = request.delivery {
        updated.notify = delivery.notify;
    }
    if let Some(enabled) = request.enabled {
        updated.enabled = enabled;
    }
    let schedule = ScheduleRequest {
        preset: updated.schedule_preset.clone(),
        expression: updated.schedule_expression.clone(),
        timezone: updated.timezone.clone(),
    };
    let schedule = request.schedule.unwrap_or(schedule);
    validate(&updated.name, &updated.instructions, &schedule)?;
    let changed =
        schedule.expression != updated.schedule_expression || schedule.timezone != updated.timezone;
    updated.schedule_preset = schedule.preset.clone();
    updated.schedule_expression = schedule.expression.clone();
    updated.timezone = schedule.timezone.clone();
    if changed || updated.next_run_at.is_none() {
        // A schedule change never fires the slot it just left.
        updated.next_run_at = first_slot(&state, &schedule)?;
    }
    let now = state.clock.now().unix_timestamp();
    let conn = database.lock();
    let stored = store::update(&conn, &updated, now).map_err(|error| {
        envelope(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL",
            &error.to_string(),
        )
    })?;
    let body = presented(&conn, &stored);
    drop(conn);
    state.automations.wake.notify_one();
    Ok(Json(body))
}

pub async fn delete_automation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::AutomationManage)
        .resource(AUTOMATIONS_ROUTE)
        .details(json!({"automation_id": id}))
        .check()?;
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    {
        let conn = database.lock();
        if !store::delete(&conn, id).map_err(|_| unavailable())? {
            return Err(envelope(
                StatusCode::NOT_FOUND,
                "AUTOMATION_NOT_FOUND",
                "this Spark has no automation with that id",
            ));
        }
    }
    Ok(Json(listing(&state)?))
}

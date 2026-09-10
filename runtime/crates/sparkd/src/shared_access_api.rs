//! Owner-only shared-access management, and the one record a guest may read about itself.

use axum::extract::{Extension, Path, State};

use axum::http::{HeaderMap, StatusCode};

use axum::response::Json;

use serde::Deserialize;

use serde_json::{Value, json};

use crate::auth::{AuthenticatedRequest, Principal};

use crate::capability::{Capability, Presence, Role};

use crate::guest::{
    DaySchedule, GrantState, GuestGrant, GuestPolicy, HourWindow, TimeZone, UsageTotals,
    WeeklySchedule,
};

use crate::idempotency::IdempotencyRequest;

use crate::state::AppState;

type ApiResult<T> = Result<T, (StatusCode, Json<Value>)>;

/// How many local days the owner's screen summarises beside today.
pub const WEEK_DAYS: i64 = 7;

pub(crate) fn envelope(code: &str, message: &str, status: StatusCode) -> (StatusCode, Json<Value>) {
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

fn internal(message: &str) -> (StatusCode, Json<Value>) {
    envelope("INTERNAL_ERROR", message, StatusCode::INTERNAL_SERVER_ERROR)
}

/// The policy fields the owner sends when creating or editing a guest's limits.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct SharedAccessLimits {
    pub display_name: String,
    #[serde(default)]
    pub allowed_models: Vec<String>,
    pub allowed_hours: Vec<DaySchedule>,
    pub time_zone: String,
    pub max_concurrent_requests: u32,
    pub daily_token_budget: u64,
    #[serde(default)]
    pub expires_at: Option<i64>,
}

impl SharedAccessLimits {
    /// Build the stored policy, keeping the lifecycle state the caller decided separately.
    pub fn policy(&self, state: GrantState) -> GuestPolicy {
        GuestPolicy {
            state,
            display_name: self.display_name.clone(),
            allowed_models: self.allowed_models.clone(),
            allowed_hours: WeeklySchedule {
                days: self.allowed_hours.clone(),
            },
            time_zone: self.time_zone.clone(),
            max_concurrent_requests: self.max_concurrent_requests,
            daily_token_budget: self.daily_token_budget,
            expires_at: self.expires_at,
        }
    }
}

/// Reject limits the owner could not have meant, naming the problem in plain words.
pub(crate) fn validated(policy: &GuestPolicy) -> ApiResult<()> {
    policy.validate().map_err(|problem| {
        envelope(
            "SHARED_ACCESS_POLICY_INVALID",
            &problem.to_string(),
            StatusCode::UNPROCESSABLE_ENTITY,
        )
    })
}

/// Verify the owner's enrolled presence key, then authorize; every shared-access change needs both.
pub(crate) fn owner_with_presence(
    state: &AppState,
    principal: &Principal,
    authenticated: &AuthenticatedRequest,
    headers: &HeaderMap,
    resource: &str,
    details: Value,
) -> ApiResult<()> {
    let presence_key = {
        let database = state
            .database
            .as_ref()
            .ok_or_else(|| internal("no database"))?;
        let guard = database.lock();
        crate::store::load_presence_key_by_device_id(&guard, &principal.device_id)
            .map_err(|error| internal(&error.to_string()))?
    };
    match crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        authenticated,
        state.clock.now(),
    ) {
        Ok(()) => state
            .require(principal, Capability::SharedAccessManage)
            .resource(resource)
            .details(details)
            .check_with_verified_presence(Presence::Fresh),
        Err(error) => {
            state
                .require(principal, Capability::SharedAccessManage)
                .resource(resource)
                .details(details)
                .check_with_verified_presence(Presence::Absent)?;
            Err(envelope(
                error.code(),
                "this change needs a fresh presence proof",
                StatusCode::FORBIDDEN,
            ))
        }
    }
}

/// The local days the owner's week covers, newest last, in the guest's own time zone.
pub(crate) fn week_of(zone: Option<&TimeZone>, now: time::OffsetDateTime) -> Vec<String> {
    let mut days = Vec::new();
    for back in (0..WEEK_DAYS).rev() {
        let instant = now.unix_timestamp() - back * 86_400;
        days.push(match zone {
            Some(zone) => zone
                .local_at(instant)
                .map(|local| local.date())
                .unwrap_or_default(),
            None => utc_date(instant),
        });
    }
    days.retain(|day| !day.is_empty());
    days
}

pub(crate) fn utc_date(unix: i64) -> String {
    time::OffsetDateTime::from_unix_timestamp(unix)
        .map(|at| {
            format!(
                "{:04}-{:02}-{:02}",
                at.year(),
                u8::from(at.month()),
                at.day()
            )
        })
        .unwrap_or_default()
}

pub(crate) fn usage_json(totals: &UsageTotals) -> Value {
    json!({
        "requests": totals.requests,
        "refusals": totals.refusals,
        "prompt_tokens": totals.prompt_tokens,
        "completion_tokens": totals.completion_tokens,
        "total_tokens": totals.total_tokens(),
    })
}

pub(crate) fn hours_json(schedule: &WeeklySchedule) -> Value {
    let days: Vec<Value> = schedule
        .days
        .iter()
        .map(|day| {
            json!({
                "weekday": day.weekday,
                "windows": day
                    .windows
                    .iter()
                    .map(window_json)
                    .collect::<Vec<Value>>(),
            })
        })
        .collect();
    json!({ "days": days })
}

fn window_json(window: &HourWindow) -> Value {
    json!({ "start_minute": window.start_minute, "end_minute": window.end_minute })
}

/// Look up the grant the owner named, refusing an unknown or non-guest device.
pub(crate) fn grant_of(state: &AppState, device_id: &uuid::Uuid) -> ApiResult<GuestGrant> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal("no database"))?;
    let guard = database.lock();
    crate::guest::grant_for_device(&guard, device_id)
        .map_err(|error| internal(&error.to_string()))?
        .ok_or_else(|| {
            envelope(
                "OPERATION_NOT_FOUND",
                "no shared access is recorded for that device",
                StatusCode::NOT_FOUND,
            )
        })
}

mod overview;
pub use overview::{list_shared_access, own_shared_access};

mod manage;
pub use manage::{revoke_shared_access, update_shared_access};

mod invitations;
pub use invitations::{CreateSharedAccessInvitation, create_shared_access_invitation};

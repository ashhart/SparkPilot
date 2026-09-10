//! Admit or refuse one guest inference request against the owner's policy, and record both outcomes.

use axum::Json;
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::auth::Principal;
use crate::capability::Role;
use crate::guest::concurrency::GuestSlot;
use crate::guest::policy::{GuestAttempt, GuestRefusal, evaluate};
use crate::guest::records;
use crate::guest::timezone::TimeZone;
use crate::state::AppState;

/// A guest request the policy admitted, holding its concurrency slot until the response ends.
#[derive(Debug)]
pub struct GuestAdmission {
    pub device_id: uuid::Uuid,
    pub local_day: String,
    /// What is left of the guest's day at admission, so one request cannot be told to generate more than that.
    pub remaining_tokens: u64,
    pub slot: GuestSlot,
}

/// Parameters a guest may never send, because guests get chat and nothing that reaches out.
pub const GUEST_FORBIDDEN_PARAMETERS: &[&str] = &[
    "tools",
    "tool_choice",
    "parallel_tool_calls",
    "store",
    "previous_response_id",
    "metadata",
    "user",
    "safety_identifier",
    "prompt_cache_key",
    "include",
];

fn envelope(code: &str, message: &str, status: StatusCode) -> (StatusCode, Json<Value>) {
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

/// Refuse a guest request that carries a parameter guests are not allowed to use.
pub fn reject_forbidden_parameters(
    principal: &Principal,
    body: &Value,
) -> Result<(), (StatusCode, Json<Value>)> {
    if Role::parse(&principal.role) != Role::Guest {
        return Ok(());
    }
    for name in GUEST_FORBIDDEN_PARAMETERS {
        if body.get(*name).is_some() {
            return Err(envelope(
                "GUEST_PARAMETER_NOT_ALLOWED",
                "shared access covers chat only; this request asked for more",
                StatusCode::UNPROCESSABLE_ENTITY,
            ));
        }
    }
    Ok(())
}

/// Refuse a route a guest must never reach, recording the denial the way an authorization denial is recorded.
pub fn refuse_guest(
    state: &AppState,
    principal: &Principal,
    resource: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    if Role::parse(&principal.role) != Role::Guest {
        return Ok(());
    }
    audit(
        state,
        principal,
        resource,
        "guest.route.refused",
        "refused",
        &json!({ "deny_reason": "ROLE_FORBIDDEN" }),
    );
    Err(envelope(
        "ROLE_FORBIDDEN",
        "shared access does not include this",
        StatusCode::FORBIDDEN,
    ))
}

/// The models a guest may name, or None when the caller is not a guest; an unreadable grant shows nothing rather than the engine's own catalogue.
pub fn allowed_models(state: &AppState, principal: &Principal) -> Option<Vec<String>> {
    if Role::parse(&principal.role) != Role::Guest {
        return None;
    }
    let Some(database) = state.database.as_ref() else {
        return Some(Vec::new());
    };
    let grant = records::grant_for_device(&database.lock(), &principal.device_id);
    Some(match grant {
        Ok(Some(grant)) => grant.policy.allowed_models,
        _ => Vec::new(),
    })
}

/// Decide one guest request. Non-guests pass straight through with no admission.
pub fn admit(
    state: &AppState,
    principal: &Principal,
    model_id: &str,
    resource: &str,
) -> Result<Option<GuestAdmission>, (StatusCode, Json<Value>)> {
    if Role::parse(&principal.role) != Role::Guest {
        return Ok(None);
    }
    let device_id = principal.device_id;
    let now = state.clock.now();
    let Some(database) = state.database.as_ref() else {
        return Err(refuse_without_record(GuestRefusal::Revoked));
    };
    let grant = {
        let connection = database.lock();
        records::grant_for_device(&connection, &device_id)
    };
    // A signed guest principal with no readable grant is refused rather than admitted on a fallback.
    let Ok(Some(grant)) = grant else {
        return Err(refuse_without_record(GuestRefusal::Revoked));
    };
    let zone = TimeZone::load(&grant.policy.time_zone).ok();
    let local_day = match &zone {
        Some(zone) => zone
            .local_at(now.unix_timestamp())
            .map(|local| local.date())
            .unwrap_or_else(|_| utc_day(now)),
        None => utc_day(now),
    };
    let Some(zone) = zone else {
        return Err(record_refusal(
            state,
            principal,
            resource,
            model_id,
            &local_day,
            GuestRefusal::ScheduleUnavailable,
        ));
    };
    let tokens_used_today = {
        let connection = database.lock();
        records::tokens_used_on(&connection, &device_id, &local_day).unwrap_or(u64::MAX)
    };
    let attempt = GuestAttempt {
        model_id,
        now_unix: now.unix_timestamp(),
        active_requests: state.guest_concurrency.active(&device_id),
        tokens_used_today,
    };
    if let Err(refusal) = evaluate(&grant.policy, &zone, &attempt) {
        return Err(record_refusal(
            state, principal, resource, model_id, &local_day, refusal,
        ));
    }
    // Take the slot under the same lock that counts it, so two requests cannot both pass the limit.
    let Some(slot) = state
        .guest_concurrency
        .acquire_below(&device_id, grant.policy.max_concurrent_requests)
    else {
        return Err(record_refusal(
            state,
            principal,
            resource,
            model_id,
            &local_day,
            GuestRefusal::ConcurrencyLimit,
        ));
    };
    audit(
        state,
        principal,
        resource,
        "guest.request.admitted",
        "accepted",
        &json!({ "model_id": model_id, "local_day": local_day }),
    );
    Ok(Some(GuestAdmission {
        device_id,
        local_day,
        remaining_tokens: grant
            .policy
            .daily_token_budget
            .saturating_sub(tokens_used_today),
        slot,
    }))
}

fn utc_day(now: time::OffsetDateTime) -> String {
    let utc = now.to_offset(time::UtcOffset::UTC);
    format!(
        "{:04}-{:02}-{:02}",
        utc.year(),
        u8::from(utc.month()),
        utc.day()
    )
}

fn refuse_without_record(refusal: GuestRefusal) -> (StatusCode, Json<Value>) {
    envelope(refusal.code(), refusal.message(), refusal.status())
}

fn record_refusal(
    state: &AppState,
    principal: &Principal,
    resource: &str,
    model_id: &str,
    local_day: &str,
    refusal: GuestRefusal,
) -> (StatusCode, Json<Value>) {
    if let Some(database) = state.database.as_ref() {
        let connection = database.lock();
        if let Err(error) = records::record_refusal(
            &connection,
            &principal.device_id,
            local_day,
            refusal.code(),
            &state.clock.now_rfc3339(),
        ) {
            tracing::error!(%error, "guest refusal could not be counted");
        }
    }
    audit(
        state,
        principal,
        resource,
        "guest.request.refused",
        "refused",
        &json!({
            "reason_code": refusal.code(),
            "model_id": model_id,
            "local_day": local_day,
        }),
    );
    state.events.emit_scoped(
        None,
        &state.identity.node_id().to_string(),
        None,
        "guest.request.refused",
        "notice",
        json!({ "reason_code": refusal.code(), "device_id": principal.device_id.to_string() }),
        crate::events::Visibility::min_role(Role::Owner),
    );
    envelope(refusal.code(), refusal.message(), refusal.status())
}

fn audit(
    state: &AppState,
    principal: &Principal,
    resource: &str,
    action: &str,
    result: &str,
    details: &Value,
) {
    let Some(database) = state.database.as_ref() else {
        return;
    };
    let connection = database.lock();
    if let Err(error) = crate::audit::append(
        &connection,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: "/v1",
            action,
            resource: Some(resource),
            result,
            operation_id: None,
            request_id: None,
            details,
        },
    ) {
        tracing::error!(%error, action, "guest decision could not be audited");
    }
}

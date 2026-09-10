//! Explicit household membership and attributed shared notes; private conversations are never read here.
use crate::{
    auth::{AuthenticatedRequest, Principal},
    idempotency::{IdempotencyRequest, StoredResponse, json_response},
    state::AppState,
    store::StoreError,
};
use axum::{
    Json,
    extract::{Extension, State},
    http::{HeaderMap, StatusCode},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

mod store;
#[cfg(test)]
mod tests;

const NOTES: &str = "/api/v1/household/notes";
const MEMBERS: &str = "/api/v1/household/members";
const MAX_NOTES: i64 = 256;
type Failure = (StatusCode, Json<Value>);

fn failure(status: StatusCode, code: &str, message: &str) -> Failure {
    (
        status,
        Json(
            json!({"error":{"code":code,"message":message,"request_id":crate::route::current_request_id()}}),
        ),
    )
}
fn unavailable() -> Failure {
    failure(
        StatusCode::SERVICE_UNAVAILABLE,
        "HOUSEHOLD_UNAVAILABLE",
        "Household notes could not be read. Reconnect and try again.",
    )
}
fn denied() -> Failure {
    failure(
        StatusCode::FORBIDDEN,
        "HOUSEHOLD_ACCESS_REQUIRED",
        "Ask the owner to add this device to the household.",
    )
}
fn stored_error(status: StatusCode, code: &str, message: &str) -> StoredResponse {
    let (_, Json(body)) = failure(status, code, message);
    StoredResponse {
        status,
        body,
        operation_id: None,
    }
}

#[derive(Debug)]
struct Member {
    name: String,
    administrator: bool,
}

/// Recheck live device and guest grants under the database lock, including after an HTTP request was authenticated.
fn eligible(conn: &Connection, id: Uuid, now: i64) -> Result<Option<Member>, StoreError> {
    let row: Option<(String, String)> = conn
        .query_row(
            "SELECT display_name,role FROM devices WHERE id=?1 AND revoked_at IS NULL",
            [id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((name, role)) = row else {
        return Ok(None);
    };
    if !matches!(
        role.as_str(),
        "owner" | "administrator" | "developer" | "user" | "observer" | "guest"
    ) {
        return Ok(None);
    }
    let administrator = matches!(role.as_str(), "owner" | "administrator");
    if let Some(grant) = crate::guest::grant_for_device(conn, &id)? {
        if grant.policy.state != crate::guest::GrantState::Active
            || grant.policy.expires_at.is_some_and(|at| now >= at)
        {
            return Ok(None);
        }
    } else if role == "guest" {
        return Ok(None);
    }
    Ok(Some(Member {
        name,
        administrator,
    }))
}

fn access(conn: &Connection, principal: &Principal, now: i64) -> Result<Member, Failure> {
    let member = eligible(conn, principal.device_id, now)
        .map_err(|_| unavailable())?
        .ok_or_else(denied)?;
    let joined: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM household_members WHERE device_id=?1)",
            [principal.device_id.to_string()],
            |row| row.get(0),
        )
        .map_err(|_| unavailable())?;
    if member.administrator || joined {
        Ok(member)
    } else {
        Err(denied())
    }
}

pub async fn snapshot(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, Failure> {
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let conn = database.lock();
    let now = state.clock.now().unix_timestamp();
    let member = access(&conn, &principal, now)?;
    let notes = store::notes(&conn, principal.device_id, member.administrator)
        .map_err(|_| unavailable())?;
    let members = store::members(&conn, now, member.administrator).map_err(|_| unavailable())?;
    Ok(Json(
        json!({"notes":notes,"members":members,"can_manage_members":member.administrator}),
    ))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NoteRequest {
    id: Uuid,
    expected_revision: u64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    delete: bool,
}

/// The stored idempotency response contains only ids and revisions, so deleting a note does not leave its text in replay records.
pub async fn save_note(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(request): Json<NoteRequest>,
) -> Result<(StatusCode, Json<Value>), Failure> {
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let mut conn = database.lock();
    let member = access(&conn, &principal, state.clock.now().unix_timestamp())?;
    let outcome = state
        .idempotency
        .execute(&mut conn, &idempotency, |transaction| {
            let result = store::save_note(
                transaction,
                &principal,
                &member,
                &request,
                &state.clock.now_rfc3339(),
            )?;
            if result.status.is_success() {
                audit(
                    transaction,
                    &state,
                    &principal,
                    NOTES,
                    if request.delete {
                        "household.note.deleted"
                    } else {
                        "household.note.saved"
                    },
                    &request.id.to_string(),
                )?;
            }
            Ok(result)
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemberRequest {
    device_id: Uuid,
    joined: bool,
}

pub async fn set_member(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(signed): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<MemberRequest>,
) -> Result<(StatusCode, Json<Value>), Failure> {
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let mut conn = database.lock();
    let member = access(&conn, &principal, state.clock.now().unix_timestamp())?;
    if !member.administrator {
        return Err(denied());
    }
    if let Some(replay) = state
        .idempotency
        .lookup(&mut conn, &idempotency)
        .map_err(|error| error.envelope())?
    {
        return Ok(json_response(&replay));
    }
    let key = crate::store::load_presence_key_by_device_id(&conn, &principal.device_id)
        .map_err(|_| unavailable())?;
    crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        key.as_deref(),
        &signed,
        state.clock.now(),
    )
    .map_err(|error| {
        failure(
            StatusCode::FORBIDDEN,
            error.code(),
            "Confirm this household access change on your device.",
        )
    })?;
    let outcome = state
        .idempotency
        .execute(&mut conn, &idempotency, |transaction| {
            let result = store::set_member(
                transaction,
                &principal,
                &request,
                state.clock.now().unix_timestamp(),
                &state.clock.now_rfc3339(),
            )?;
            if result.status.is_success() {
                audit(
                    transaction,
                    &state,
                    &principal,
                    MEMBERS,
                    if request.joined {
                        "household.member.added"
                    } else {
                        "household.member.removed"
                    },
                    &request.device_id.to_string(),
                )?;
            }
            Ok(result)
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

fn audit(
    conn: &Connection,
    state: &AppState,
    principal: &Principal,
    route: &str,
    action: &str,
    id: &str,
) -> Result<(), StoreError> {
    crate::audit::append(
        conn,
        state.clock.as_ref(),
        &crate::audit::AuditDraft {
            actor_device_id: Some(principal.device_id),
            actor_role: Some(&principal.role),
            source_route: route,
            action,
            resource: Some(id),
            result: "accepted",
            operation_id: None,
            request_id: None,
            details: &json!({"id":id}),
        },
    )
    .map(|_| ())
}

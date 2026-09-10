//! Persist guest grants and the usage that enforces their budgets, keyed by the owner's local day.

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, params};

use crate::capability::Role;
use crate::guest::policy::{GrantState, GuestPolicy, WeeklySchedule};
use crate::store::StoreError;

/// One guest grant as the owner's screen and the inference gate read it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuestGrant {
    pub invitation_id: uuid::Uuid,
    pub device_id: Option<uuid::Uuid>,
    pub policy: GuestPolicy,
    pub created_by_device_id: uuid::Uuid,
    pub created_at: String,
    pub updated_at: String,
    pub joined_at: Option<String>,
    pub confirmed_at: Option<String>,
    pub revoked_at: Option<String>,
}

/// The counters one guest ran up over one or more local days.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct UsageTotals {
    pub requests: u64,
    pub refusals: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
}

impl UsageTotals {
    pub fn total_tokens(&self) -> u64 {
        self.prompt_tokens.saturating_add(self.completion_tokens)
    }
}

const GRANT_COLUMNS: &str = "invitation_id, device_id, display_name, state, allowed_models_json,
     allowed_hours_json, time_zone, max_concurrent_requests, daily_token_budget, expires_at,
     created_by_device_id, created_at, updated_at, joined_at, confirmed_at, revoked_at";

/// Write a guest grant beside the invitation that carries it; the device binds later, at the claim.
pub fn insert_grant(
    conn: &Connection,
    invitation_id: &uuid::Uuid,
    created_by: &uuid::Uuid,
    policy: &GuestPolicy,
    now: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO guest_grants
            (invitation_id, device_id, display_name, state, allowed_models_json,
             allowed_hours_json, time_zone, max_concurrent_requests, daily_token_budget,
             expires_at, created_by_device_id, created_at, updated_at)
         VALUES (?1, NULL, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)",
        params![
            invitation_id.to_string(),
            policy.display_name,
            policy.state.name(),
            serde_json::to_string(&policy.allowed_models).unwrap_or_else(|_| "[]".into()),
            serde_json::to_string(&policy.allowed_hours).map_err(json_error)?,
            policy.time_zone,
            policy.max_concurrent_requests,
            policy.daily_token_budget as i64,
            policy.expires_at,
            created_by.to_string(),
            now,
        ],
    )?;
    Ok(())
}

/// Bind one guest device to its invitation, refusing a second claim on the same grant.
pub fn bind_grant_to_device(
    conn: &Connection,
    invitation_id: &uuid::Uuid,
    device_id: &uuid::Uuid,
    now: &str,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE guest_grants
            SET device_id = ?2, joined_at = ?3, updated_at = ?3
          WHERE invitation_id = ?1 AND device_id IS NULL AND state <> 'revoked'",
        params![invitation_id.to_string(), device_id.to_string(), now],
    )?;
    if changed == 0 {
        return Err(StoreError::InvitationUnavailable);
    }
    Ok(())
}

/// Move a bound grant through its lifecycle. Revocation is final.
pub fn set_grant_state(
    conn: &Connection,
    device_id: &uuid::Uuid,
    state: GrantState,
    now: &str,
) -> Result<(), StoreError> {
    let confirmed = matches!(state, GrantState::Active);
    let revoked = matches!(state, GrantState::Revoked);
    let changed = conn.execute(
        "UPDATE guest_grants
            SET state = ?2,
                updated_at = ?3,
                confirmed_at = CASE WHEN ?4 AND confirmed_at IS NULL THEN ?3 ELSE confirmed_at END,
                revoked_at = CASE WHEN ?5 THEN ?3 ELSE revoked_at END
          WHERE device_id = ?1 AND state <> 'revoked'",
        params![device_id.to_string(), state.name(), now, confirmed, revoked],
    )?;
    if changed == 0 {
        return Err(StoreError::NotFound("guest grant"));
    }
    Ok(())
}

/// Replace a guest's limits without disturbing where the grant is in its lifecycle.
pub fn update_policy(
    conn: &Connection,
    device_id: &uuid::Uuid,
    policy: &GuestPolicy,
    now: &str,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE guest_grants
            SET display_name = ?2, allowed_models_json = ?3, allowed_hours_json = ?4,
                time_zone = ?5, max_concurrent_requests = ?6, daily_token_budget = ?7,
                expires_at = ?8, updated_at = ?9
          WHERE device_id = ?1 AND state <> 'revoked'",
        params![
            device_id.to_string(),
            policy.display_name,
            serde_json::to_string(&policy.allowed_models).unwrap_or_else(|_| "[]".into()),
            serde_json::to_string(&policy.allowed_hours).map_err(json_error)?,
            policy.time_zone,
            policy.max_concurrent_requests,
            policy.daily_token_budget as i64,
            policy.expires_at,
            now,
        ],
    )?;
    if changed == 0 {
        return Err(StoreError::NotFound("guest grant"));
    }
    Ok(())
}

pub fn grant_by_invitation(
    conn: &Connection,
    invitation_id: &uuid::Uuid,
) -> Result<Option<GuestGrant>, StoreError> {
    let sql = format!("SELECT {GRANT_COLUMNS} FROM guest_grants WHERE invitation_id = ?1");
    Ok(conn
        .query_row(&sql, params![invitation_id.to_string()], read_grant)
        .optional()?)
}

pub fn grant_for_device(
    conn: &Connection,
    device_id: &uuid::Uuid,
) -> Result<Option<GuestGrant>, StoreError> {
    let sql = format!("SELECT {GRANT_COLUMNS} FROM guest_grants WHERE device_id = ?1");
    Ok(conn
        .query_row(&sql, params![device_id.to_string()], read_grant)
        .optional()?)
}

pub fn list_grants(conn: &Connection) -> Result<Vec<GuestGrant>, StoreError> {
    let sql = format!("SELECT {GRANT_COLUMNS} FROM guest_grants ORDER BY created_at DESC");
    let mut statement = conn.prepare(&sql)?;
    let rows = statement.query_map([], read_grant)?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

/// Pin a device to the guest role while it holds a grant; a withdrawn grant still pins one stored at the role guests are given, so revoking can only narrow reach.
pub fn effective_role(
    conn: &Connection,
    device_id: &uuid::Uuid,
    stored: Role,
) -> Result<Option<Role>, StoreError> {
    let state: Option<String> = conn
        .query_row(
            "SELECT state FROM guest_grants WHERE device_id = ?1",
            params![device_id.to_string()],
            |row| row.get(0),
        )
        .optional()?;
    Ok(match state.as_deref() {
        None => None,
        // Release the pin only where the owner deliberately raised the device after the withdrawal.
        Some("revoked") if stored > Role::Observer => None,
        Some(_) => Some(Role::Guest),
    })
}

/// Count one served guest request against the owner's local day.
pub fn record_request(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_day: &str,
    prompt_tokens: u64,
    completion_tokens: u64,
    now: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO guest_usage
            (device_id, local_day, requests, refusals, prompt_tokens, completion_tokens, updated_at)
         VALUES (?1, ?2, 1, 0, ?3, ?4, ?5)
         ON CONFLICT(device_id, local_day) DO UPDATE SET
            requests = requests + 1,
            prompt_tokens = prompt_tokens + ?3,
            completion_tokens = completion_tokens + ?4,
            updated_at = ?5",
        params![
            device_id.to_string(),
            local_day,
            prompt_tokens as i64,
            completion_tokens as i64,
            now
        ],
    )?;
    Ok(())
}

/// Count one refused guest request, both in the day's total and against its reason.
pub fn record_refusal(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_day: &str,
    reason_code: &str,
    now: &str,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO guest_usage
            (device_id, local_day, requests, refusals, prompt_tokens, completion_tokens, updated_at)
         VALUES (?1, ?2, 0, 1, 0, 0, ?3)
         ON CONFLICT(device_id, local_day) DO UPDATE SET
            refusals = refusals + 1,
            updated_at = ?3",
        params![device_id.to_string(), local_day, now],
    )?;
    conn.execute(
        "INSERT INTO guest_refusals (device_id, local_day, reason_code, refusals)
         VALUES (?1, ?2, ?3, 1)
         ON CONFLICT(device_id, local_day, reason_code) DO UPDATE SET refusals = refusals + 1",
        params![device_id.to_string(), local_day, reason_code],
    )?;
    Ok(())
}

pub fn daily_usage(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_day: &str,
) -> Result<UsageTotals, StoreError> {
    usage_over(conn, device_id, &[local_day.to_owned()])
}

/// The tokens one guest has spent on a local day, which is what the budget compares against.
pub fn tokens_used_on(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_day: &str,
) -> Result<u64, StoreError> {
    Ok(daily_usage(conn, device_id, local_day)?.total_tokens())
}

pub fn usage_over(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_days: &[String],
) -> Result<UsageTotals, StoreError> {
    let mut totals = UsageTotals::default();
    let mut statement = conn.prepare(
        "SELECT requests, refusals, prompt_tokens, completion_tokens
           FROM guest_usage WHERE device_id = ?1 AND local_day = ?2",
    )?;
    for day in local_days {
        let row = statement
            .query_row(params![device_id.to_string(), day], |row| {
                Ok(UsageTotals {
                    requests: row.get::<_, i64>(0)? as u64,
                    refusals: row.get::<_, i64>(1)? as u64,
                    prompt_tokens: row.get::<_, i64>(2)? as u64,
                    completion_tokens: row.get::<_, i64>(3)? as u64,
                })
            })
            .optional()?;
        if let Some(row) = row {
            totals.requests += row.requests;
            totals.refusals += row.refusals;
            totals.prompt_tokens += row.prompt_tokens;
            totals.completion_tokens += row.completion_tokens;
        }
    }
    Ok(totals)
}

pub fn refusals_by_reason(
    conn: &Connection,
    device_id: &uuid::Uuid,
    local_days: &[String],
) -> Result<BTreeMap<String, u64>, StoreError> {
    let mut counts: BTreeMap<String, u64> = BTreeMap::new();
    let mut statement = conn.prepare(
        "SELECT reason_code, refusals FROM guest_refusals WHERE device_id = ?1 AND local_day = ?2",
    )?;
    for day in local_days {
        let rows = statement.query_map(params![device_id.to_string(), day], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as u64))
        })?;
        for row in rows {
            let (reason, count) = row?;
            *counts.entry(reason).or_default() += count;
        }
    }
    Ok(counts)
}

fn read_grant(row: &rusqlite::Row<'_>) -> rusqlite::Result<GuestGrant> {
    let allowed_models: Vec<String> =
        serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or_default();
    let allowed_hours: WeeklySchedule = serde_json::from_str(&row.get::<_, String>(5)?)
        .unwrap_or_else(|_| WeeklySchedule::closed());
    Ok(GuestGrant {
        invitation_id: parse_uuid(row.get::<_, String>(0)?)?,
        device_id: row
            .get::<_, Option<String>>(1)?
            .map(parse_uuid)
            .transpose()?,
        policy: GuestPolicy {
            display_name: row.get(2)?,
            state: GrantState::parse(&row.get::<_, String>(3)?),
            allowed_models,
            allowed_hours,
            time_zone: row.get(6)?,
            max_concurrent_requests: row.get::<_, i64>(7)? as u32,
            daily_token_budget: row.get::<_, i64>(8)?.max(0) as u64,
            expires_at: row.get(9)?,
        },
        created_by_device_id: parse_uuid(row.get::<_, String>(10)?)?,
        created_at: row.get(11)?,
        updated_at: row.get(12)?,
        joined_at: row.get(13)?,
        confirmed_at: row.get(14)?,
        revoked_at: row.get(15)?,
    })
}

fn parse_uuid(text: String) -> rusqlite::Result<uuid::Uuid> {
    uuid::Uuid::parse_str(&text).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

fn json_error(error: serde_json::Error) -> StoreError {
    StoreError::Sqlite(error.to_string())
}

#[cfg(test)]
#[path = "records_tests.rs"]
mod tests;

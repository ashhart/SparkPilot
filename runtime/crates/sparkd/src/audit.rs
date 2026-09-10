//! Tamper-evident audit records for consequential control-plane decisions.

use axum::{Json, http::StatusCode};
use rusqlite::Connection;
use serde::Serialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::clock::UtcClock;
use crate::crypto::sha256_hex;
use crate::store::StoreError;

pub struct AuditDraft<'a> {
    pub actor_device_id: Option<Uuid>,
    pub actor_role: Option<&'a str>,
    pub source_route: &'a str,
    pub action: &'a str,
    pub resource: Option<&'a str>,
    pub result: &'a str,
    pub operation_id: Option<Uuid>,
    pub request_id: Option<Uuid>,
    pub details: &'a Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuditRecord {
    pub sequence: i64,
    pub previous_hash: Option<Vec<u8>>,
    pub record_hash: Vec<u8>,
}

pub fn append(
    conn: &Connection,
    clock: &dyn UtcClock,
    draft: &AuditDraft<'_>,
) -> Result<AuditRecord, StoreError> {
    validate_draft(draft)?;
    let details = canonical_value(draft.details);
    let details_json = serde_json::to_string(&details).map_err(audit_error)?;
    if details_json.len() > 16 * 1024 {
        return Err(audit_error("audit details exceed 16 KiB"));
    }

    let previous = conn
        .query_row(
            "SELECT sequence, record_hash FROM audit_records ORDER BY sequence DESC LIMIT 1",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Vec<u8>>(1)?)),
        )
        .optional()
        .map_err(audit_error)?;
    let (sequence, previous_hash) = match previous {
        Some((sequence, hash)) => {
            if hash.len() != 32 {
                return Err(audit_error("previous audit hash has invalid length"));
            }
            (sequence + 1, Some(hash))
        }
        None => (1, None),
    };
    let occurred_at = clock.now_rfc3339();
    let actor_device_id = draft.actor_device_id.map(|id| id.to_string());
    let operation_id = draft.operation_id.map(|id| id.to_string());
    let request_id = draft.request_id.map(|id| id.to_string());
    let hash_payload = HashPayload {
        sequence,
        occurred_at: &occurred_at,
        actor_device_id: actor_device_id.as_deref(),
        actor_role: draft.actor_role,
        source_route: draft.source_route,
        action: draft.action,
        resource: draft.resource,
        result: draft.result,
        operation_id: operation_id.as_deref(),
        request_id: request_id.as_deref(),
        details: &details,
        previous_hash: previous_hash.as_deref().map(hex::encode),
    };
    let canonical = serde_json::to_vec(&hash_payload).map_err(audit_error)?;
    let record_hash = hex::decode(sha256_hex(&canonical))
        .map_err(|error| audit_error(format!("audit hash encoding failed: {error}")))?;

    conn.execute(
        "INSERT INTO audit_records
            (sequence, occurred_at, actor_device_id, actor_role, source_route,
             action, resource, result, operation_id, request_id, details_json,
             previous_hash, record_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        rusqlite::params![
            sequence,
            occurred_at,
            actor_device_id,
            draft.actor_role,
            draft.source_route,
            draft.action,
            draft.resource,
            draft.result,
            operation_id,
            request_id,
            details_json,
            previous_hash,
            record_hash,
        ],
    )
    .map_err(audit_error)?;
    Ok(AuditRecord {
        sequence,
        previous_hash,
        record_hash,
    })
}

/// How many web tool calls the chain records since `since`, so the rolling-hour ceiling is enforced from durable evidence.
pub fn web_calls_since(conn: &Connection, since: &str) -> Result<usize, StoreError> {
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM audit_records
              WHERE (action LIKE 'web.search.%' OR action LIKE 'web.fetch.%')
                AND occurred_at >= ?1",
            rusqlite::params![since],
            |row| row.get(0),
        )
        .map_err(audit_error)?;
    Ok(count.max(0) as usize)
}

/// Use an immediate transaction for standalone decisions; accepted mutations append within their existing operation transaction.
pub fn append_committed(
    database: &parking_lot::Mutex<Connection>,
    clock: &dyn UtcClock,
    draft: &AuditDraft<'_>,
) -> Result<AuditRecord, StoreError> {
    let mut connection = database.lock();
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(audit_error)?;
    let record = append(&transaction, clock, draft)?;
    transaction.commit().map_err(audit_error)?;
    Ok(record)
}

/// Fail sensitive mutations closed with a retryable error when audit-chain extension is unavailable.
pub fn unavailable_envelope(_error: StoreError) -> (StatusCode, Json<Value>) {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(json!({
            "error": {
                "code": "AUDIT_UNAVAILABLE",
                "message": "The audit trail is unavailable; no change was accepted",
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

pub fn response_code(envelope: &(StatusCode, Json<Value>), fallback: &str) -> String {
    envelope
        .1
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(Value::as_str)
        .unwrap_or(fallback)
        .to_owned()
}

/// Verify hash linkage and sequence continuity; without an external anchor this cannot detect wholesale replacement of the chain.
pub fn verify_chain(conn: &Connection) -> Result<Option<i64>, StoreError> {
    let mut statement = conn
        .prepare(
            "SELECT sequence, occurred_at, actor_device_id, actor_role, source_route,
                    action, resource, result, operation_id, request_id, details_json,
                    previous_hash, record_hash
               FROM audit_records ORDER BY sequence ASC",
        )
        .map_err(audit_error)?;
    let mut rows = statement.query([]).map_err(audit_error)?;
    let mut previous: Option<Vec<u8>> = None;
    // Require uninterrupted sequence numbers from one, because valid surviving links alone cannot prove missing records.
    let mut expected_sequence: i64 = 1;
    while let Some(row) = rows.next().map_err(audit_error)? {
        let sequence: i64 = row.get(0).map_err(audit_error)?;
        if sequence != expected_sequence {
            return Ok(Some(sequence));
        }
        expected_sequence = sequence.saturating_add(1);
        let occurred_at: String = row.get(1).map_err(audit_error)?;
        let actor_device_id: Option<String> = row.get(2).map_err(audit_error)?;
        let actor_role: Option<String> = row.get(3).map_err(audit_error)?;
        let source_route: String = row.get(4).map_err(audit_error)?;
        let action: String = row.get(5).map_err(audit_error)?;
        let resource: Option<String> = row.get(6).map_err(audit_error)?;
        let result: String = row.get(7).map_err(audit_error)?;
        let operation_id: Option<String> = row.get(8).map_err(audit_error)?;
        let request_id: Option<String> = row.get(9).map_err(audit_error)?;
        let details_json: String = row.get(10).map_err(audit_error)?;
        let stored_previous: Option<Vec<u8>> = row.get(11).map_err(audit_error)?;
        let stored_hash: Vec<u8> = row.get(12).map_err(audit_error)?;
        if stored_previous != previous {
            return Ok(Some(sequence));
        }
        let details: Value = serde_json::from_str(&details_json).map_err(audit_error)?;
        let payload = HashPayload {
            sequence,
            occurred_at: &occurred_at,
            actor_device_id: actor_device_id.as_deref(),
            actor_role: actor_role.as_deref(),
            source_route: &source_route,
            action: &action,
            resource: resource.as_deref(),
            result: &result,
            operation_id: operation_id.as_deref(),
            request_id: request_id.as_deref(),
            details: &canonical_value(&details),
            previous_hash: previous.as_deref().map(hex::encode),
        };
        let canonical = serde_json::to_vec(&payload).map_err(audit_error)?;
        let expected = hex::decode(sha256_hex(&canonical)).map_err(audit_error)?;
        if stored_hash != expected {
            return Ok(Some(sequence));
        }
        previous = Some(stored_hash);
    }
    Ok(None)
}

/// Derive completion authority from the accepted audit record, never mutable operation input; leave legacy unaudited operations untouched.
pub fn append_operation_terminal(
    conn: &Connection,
    clock: &dyn UtcClock,
    operation_id: Uuid,
    terminal_state: &str,
    error_code: Option<&str>,
) -> Result<Option<AuditRecord>, StoreError> {
    let accepted = conn
        .query_row(
            "SELECT actor_device_id, actor_role, source_route, action, resource
               FROM audit_records
              WHERE operation_id = ?1 AND result = 'accepted'
              ORDER BY sequence ASC LIMIT 1",
            [operation_id.to_string()],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            },
        )
        .optional()
        .map_err(audit_error)?;
    let Some((actor_device_id, actor_role, source_route, action, resource)) = accepted else {
        return Ok(None);
    };
    let actor_device_id = actor_device_id
        .map(|value| Uuid::parse_str(&value).map_err(audit_error))
        .transpose()?;
    let result = match terminal_state {
        "succeeded" => "succeeded",
        "failed" | "cancelled" => "failed",
        other => {
            return Err(audit_error(format!(
                "invalid terminal audit state: {other}"
            )));
        }
    };
    let details = match error_code {
        Some(code) => json!({ "error_code": code }),
        None => json!({}),
    };
    append(
        conn,
        clock,
        &AuditDraft {
            actor_device_id,
            actor_role: actor_role.as_deref(),
            source_route: &source_route,
            action: &action,
            resource: resource.as_deref(),
            result,
            operation_id: Some(operation_id),
            request_id: None,
            details: &details,
        },
    )
    .map(Some)
}

#[allow(clippy::too_many_arguments)]
pub fn append_refusal(
    database: &parking_lot::Mutex<Connection>,
    clock: &dyn UtcClock,
    actor_device_id: Uuid,
    actor_role: &str,
    source_route: &str,
    action: &str,
    resource: Option<&str>,
    request_id: Option<Uuid>,
    reason_code: &str,
) -> Result<AuditRecord, StoreError> {
    let details = serde_json::json!({ "reason_code": reason_code });
    append_committed(
        database,
        clock,
        &AuditDraft {
            actor_device_id: Some(actor_device_id),
            actor_role: Some(actor_role),
            source_route,
            action,
            resource,
            result: "refused",
            operation_id: None,
            request_id,
            details: &details,
        },
    )
}

use rusqlite::OptionalExtension as _;

#[derive(Serialize)]
struct HashPayload<'a> {
    sequence: i64,
    occurred_at: &'a str,
    actor_device_id: Option<&'a str>,
    actor_role: Option<&'a str>,
    source_route: &'a str,
    action: &'a str,
    resource: Option<&'a str>,
    result: &'a str,
    operation_id: Option<&'a str>,
    request_id: Option<&'a str>,
    details: &'a Value,
    previous_hash: Option<String>,
}

fn validate_draft(draft: &AuditDraft<'_>) -> Result<(), StoreError> {
    if !draft.source_route.starts_with('/')
        || draft.source_route.contains(['?', '#'])
        || draft.source_route.len() > 256
    {
        return Err(audit_error(
            "audit source route must be a bounded route template",
        ));
    }
    if draft.action.is_empty() || draft.action.len() > 120 {
        return Err(audit_error("audit action is invalid"));
    }
    if !matches!(
        draft.result,
        "accepted" | "refused" | "succeeded" | "failed"
    ) {
        return Err(audit_error("audit result is invalid"));
    }
    if let Some(resource) = draft.resource
        && (resource.len() > 512 || resource.contains(['?', '#']))
    {
        return Err(audit_error("audit resource is invalid"));
    }
    reject_prohibited_keys(draft.details)
}

fn reject_prohibited_keys(value: &Value) -> Result<(), StoreError> {
    match value {
        Value::Object(fields) => {
            for (key, value) in fields {
                let key = key.to_ascii_lowercase().replace('-', "_");
                const PROHIBITED: &[&str] = &[
                    "body",
                    "credential",
                    "passphrase",
                    "password",
                    "prompt",
                    "route",
                    "secret",
                    "token",
                    "user_presence",
                ];
                if PROHIBITED.iter().any(|word| key.contains(word)) {
                    return Err(audit_error(format!(
                        "audit details contain prohibited key: {key}"
                    )));
                }
                reject_prohibited_keys(value)?;
            }
        }
        Value::Array(values) => {
            for value in values {
                reject_prohibited_keys(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn canonical_value(value: &Value) -> Value {
    match value {
        Value::Object(fields) => {
            let mut keys = fields.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            Value::Object(
                keys.into_iter()
                    .map(|key| (key.clone(), canonical_value(&fields[key])))
                    .collect(),
            )
        }
        Value::Array(values) => Value::Array(values.iter().map(canonical_value).collect()),
        value => value.clone(),
    }
}

fn audit_error(error: impl std::fmt::Display) -> StoreError {
    StoreError::Audit(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualUtcClock;
    use crate::migration;
    use serde_json::json;
    use time::{OffsetDateTime, format_description::well_known::Rfc3339};

    fn clock() -> ManualUtcClock {
        ManualUtcClock::new(OffsetDateTime::parse("2026-08-28T09:30:00Z", &Rfc3339).unwrap())
    }

    fn migrated() -> Connection {
        let mut conn = Connection::open_in_memory().unwrap();
        migration::migrate(&mut conn).unwrap();
        conn
    }

    fn draft<'a>(actor: Uuid, operation: Uuid, details: &'a Value) -> AuditDraft<'a> {
        AuditDraft {
            actor_device_id: Some(actor),
            actor_role: Some("administrator"),
            source_route: "/api/v1/inference/load",
            action: "model.load",
            resource: Some("model/example-32b"),
            result: "accepted",
            operation_id: Some(operation),
            request_id: Some(Uuid::nil()),
            details,
        }
    }

    #[test]
    fn records_link_and_hash_deterministically() {
        let conn = migrated();
        let clock = clock();
        let actor = Uuid::from_u128(1);
        let first_operation = Uuid::from_u128(2);
        let first_details = json!({"profile_id": "balanced", "replace_active": false});
        let first = append(
            &conn,
            &clock,
            &draft(actor, first_operation, &first_details),
        )
        .unwrap();
        assert_eq!(first.sequence, 1);
        assert_eq!(first.previous_hash, None);
        assert_eq!(first.record_hash.len(), 32);

        let second_details = json!({"replace_active": true, "profile_id": "balanced"});
        let second = append(
            &conn,
            &clock,
            &draft(actor, Uuid::from_u128(3), &second_details),
        )
        .unwrap();
        assert_eq!(second.sequence, 2);
        assert_eq!(
            second.previous_hash.as_deref(),
            Some(first.record_hash.as_slice())
        );

        let persisted: (String, String, String, String, Vec<u8>, Vec<u8>) = conn
            .query_row(
                "SELECT actor_device_id, actor_role, action, resource, previous_hash, record_hash
                   FROM audit_records WHERE sequence = 2",
                [],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(persisted.0, actor.to_string());
        assert_eq!(persisted.1, "administrator");
        assert_eq!(persisted.2, "model.load");
        assert_eq!(persisted.3, "model/example-32b");
        assert_eq!(persisted.4, first.record_hash);
        assert_eq!(persisted.5, second.record_hash);
    }

    #[test]
    fn chain_continues_after_database_restart() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("runtime.db");
        let actor = Uuid::from_u128(10);
        let operation = Uuid::from_u128(11);
        let details = json!({"profile_id": "balanced"});
        let first_hash = {
            let mut conn = Connection::open(&path).unwrap();
            migration::migrate_with_recovery_point(&mut conn, &path).unwrap();
            append(&conn, &clock(), &draft(actor, operation, &details))
                .unwrap()
                .record_hash
        };
        let conn = Connection::open(&path).unwrap();
        let second = append(
            &conn,
            &clock(),
            &draft(actor, Uuid::from_u128(12), &details),
        )
        .unwrap();
        assert_eq!(second.sequence, 2);
        assert_eq!(second.previous_hash, Some(first_hash));
    }

    #[test]
    fn canonical_detail_order_produces_the_same_hash() {
        let first = migrated();
        let second = migrated();
        let actor = Uuid::from_u128(30);
        let operation = Uuid::from_u128(31);
        let mut left = serde_json::Map::new();
        left.insert("zeta".into(), json!(2));
        left.insert("alpha".into(), json!({"two": 2, "one": 1}));
        let mut right = serde_json::Map::new();
        right.insert("alpha".into(), json!({"one": 1, "two": 2}));
        right.insert("zeta".into(), json!(2));
        let left = Value::Object(left);
        let right = Value::Object(right);

        let left_hash = append(&first, &clock(), &draft(actor, operation, &left))
            .unwrap()
            .record_hash;
        let right_hash = append(&second, &clock(), &draft(actor, operation, &right))
            .unwrap()
            .record_hash;
        assert_eq!(left_hash, right_hash);
    }

    #[test]
    fn secret_shaped_detail_keys_are_rejected_without_a_row() {
        let conn = migrated();
        let details = json!({"provider_token": "do-not-store"});
        let error = append(
            &conn,
            &clock(),
            &draft(Uuid::from_u128(20), Uuid::from_u128(21), &details),
        )
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("audit details contain prohibited key")
        );
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM audit_records", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }
}

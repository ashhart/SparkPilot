//! Commit mutation responses and their operations atomically so retries observe both or neither.

use std::sync::Arc;

use axum::Json;
use axum::extract::FromRequestParts;
use axum::http::{StatusCode, request::Parts};
use rusqlite::{OptionalExtension, TransactionBehavior};
use serde_json::{Value, json};
use time::Duration;
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

use crate::auth::{AuthenticatedBody, Principal};
use crate::clock::UtcClock;
use crate::crypto::sha256_hex;
use crate::jobs::JobService;
use crate::store;

pub const HEADER_IDEMPOTENCY_KEY: &str = "idempotency-key";
pub const RETENTION_SECONDS: i64 = 86_400;

#[derive(Debug, Clone)]
pub struct IdempotencyRequest {
    pub device_id: Uuid,
    pub method: String,
    pub path: String,
    pub key: Uuid,
    pub body_hash: String,
    /// Persist generated UUID correlation IDs while omitting non-UUID caller values from audit storage.
    pub request_id: Option<Uuid>,
}

impl<S> FromRequestParts<S> for IdempotencyRequest
where
    S: Send + Sync,
{
    type Rejection = (StatusCode, Json<Value>);

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let principal = parts
            .extensions
            .get::<Principal>()
            .cloned()
            .ok_or_else(|| {
                error(
                    StatusCode::UNAUTHORIZED,
                    "DEVICE_NOT_PAIRED",
                    "authenticated device context is missing",
                )
            })?;
        let body = parts
            .extensions
            .get::<AuthenticatedBody>()
            .cloned()
            .ok_or_else(|| {
                error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL",
                    "authenticated request body is missing",
                )
            })?;
        let raw_key = parts
            .headers
            .get(HEADER_IDEMPOTENCY_KEY)
            .ok_or_else(|| {
                error(
                    StatusCode::BAD_REQUEST,
                    "IDEMPOTENCY_KEY_REQUIRED",
                    "Idempotency-Key is required for mutations",
                )
            })?
            .to_str()
            .map_err(|_| {
                error(
                    StatusCode::BAD_REQUEST,
                    "IDEMPOTENCY_KEY_INVALID",
                    "Idempotency-Key must be a UUID",
                )
            })?;
        let key = Uuid::parse_str(raw_key).map_err(|_| {
            error(
                StatusCode::BAD_REQUEST,
                "IDEMPOTENCY_KEY_INVALID",
                "Idempotency-Key must be a UUID",
            )
        })?;

        Ok(Self {
            device_id: principal.device_id,
            method: parts.method.as_str().to_uppercase(),
            // Include path and query in idempotency scope, matching the signed canonical request.
            path: match parts.uri.query() {
                Some(query) => format!("{}?{}", parts.uri.path(), query),
                None => parts.uri.path().to_owned(),
            },
            key,
            body_hash: sha256_hex(&body.0),
            request_id: parts
                .headers
                .get(crate::route::REQUEST_ID_HEADER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| Uuid::parse_str(value).ok()),
        })
    }
}

fn error(status: StatusCode, code: &str, message: &str) -> (StatusCode, Json<Value>) {
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

#[derive(Debug, Clone, PartialEq)]
pub struct StoredResponse {
    pub status: StatusCode,
    pub body: Value,
    pub operation_id: Option<Uuid>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct IdempotencyOutcome {
    pub response: StoredResponse,
    pub created: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum IdempotencyError {
    #[error("idempotency key was already used with a different request body")]
    KeyReused,
    #[error(transparent)]
    Store(#[from] store::StoreError),
    #[error("stored idempotency response is invalid: {0}")]
    Corrupt(String),
}

impl From<rusqlite::Error> for IdempotencyError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Store(store::StoreError::from(error))
    }
}

impl IdempotencyError {
    pub fn envelope(&self) -> (StatusCode, Json<Value>) {
        match self {
            Self::KeyReused => error(
                StatusCode::CONFLICT,
                "IDEMPOTENCY_KEY_REUSED",
                "Idempotency-Key was already used with a different request body",
            ),
            Self::Store(store::StoreError::Audit(_)) => error(
                StatusCode::SERVICE_UNAVAILABLE,
                "AUDIT_UNAVAILABLE",
                "The audit trail is unavailable; no change was accepted",
            ),
            Self::Store(_) | Self::Corrupt(_) => error(
                StatusCode::INTERNAL_SERVER_ERROR,
                "INTERNAL",
                &self.to_string(),
            ),
        }
    }
}

#[derive(Clone)]
pub struct IdempotencyService {
    clock: Arc<dyn UtcClock>,
    /// Serialize external side-effect admission and result recording so duplicates cannot observe provisional responses.
    admission: Arc<parking_lot::Mutex<()>>,
}

struct ExistingRecord {
    body_hash: String,
    status_code: i64,
    response_json: Option<String>,
    operation_id: Option<String>,
    expires_at: String,
}

impl std::fmt::Debug for IdempotencyService {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("IdempotencyService").finish()
    }
}

impl IdempotencyService {
    pub fn new(clock: Arc<dyn UtcClock>) -> Self {
        Self {
            clock,
            admission: Arc::new(parking_lot::Mutex::new(())),
        }
    }

    pub fn admission_guard(&self) -> parking_lot::MutexGuard<'_, ()> {
        self.admission.lock()
    }

    /// Hold admission across replay lookup, external effects and final persistence while releasing the database lock during effects.
    pub fn lookup(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
    ) -> Result<Option<IdempotencyOutcome>, IdempotencyError> {
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let outcome = self.lookup_in(&transaction, request, self.clock.now())?;
        transaction.commit()?;
        Ok(outcome)
    }

    pub fn execute<F>(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
        create: F,
    ) -> Result<IdempotencyOutcome, IdempotencyError>
    where
        F: FnOnce(&rusqlite::Transaction<'_>) -> Result<StoredResponse, store::StoreError>,
    {
        let now = self.clock.now();
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(outcome) = self.lookup_in(&transaction, request, now)? {
            transaction.commit()?;
            return Ok(outcome);
        }

        let response = create(&transaction)?;
        let created_at = format_utc(now);
        let expires_at = format_utc(now + Duration::seconds(RETENTION_SECONDS));
        transaction.execute(
            "INSERT INTO idempotency_records
                (device_id, method, path, idempotency_key, body_hash, status_code,
                 response_json, operation_id, created_at, expires_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            rusqlite::params![
                request.device_id.to_string(),
                request.method,
                request.path,
                request.key.to_string(),
                request.body_hash,
                i64::from(response.status.as_u16()),
                serde_json::to_string(&response.body)
                    .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?,
                response.operation_id.map(|id| id.to_string()),
                created_at,
                expires_at,
            ],
        )?;
        transaction.commit()?;
        Ok(IdempotencyOutcome {
            response,
            created: true,
        })
    }

    fn lookup_in(
        &self,
        transaction: &rusqlite::Transaction<'_>,
        request: &IdempotencyRequest,
        now: time::OffsetDateTime,
    ) -> Result<Option<IdempotencyOutcome>, IdempotencyError> {
        store::prune_expired_records(transaction, &format_utc(now))?;
        let existing: Option<ExistingRecord> = transaction
            .query_row(
                "SELECT body_hash, status_code, response_json, operation_id, expires_at
                   FROM idempotency_records
                  WHERE device_id = ?1 AND method = ?2 AND path = ?3 AND idempotency_key = ?4",
                rusqlite::params![
                    request.device_id.to_string(),
                    request.method,
                    request.path,
                    request.key.to_string(),
                ],
                |row| {
                    Ok(ExistingRecord {
                        body_hash: row.get(0)?,
                        status_code: row.get(1)?,
                        response_json: row.get(2)?,
                        operation_id: row.get(3)?,
                        expires_at: row.get(4)?,
                    })
                },
            )
            .optional()?;

        if let Some(existing) = existing {
            let expiry = time::OffsetDateTime::parse(
                &existing.expires_at,
                &time::format_description::well_known::Rfc3339,
            )
            .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?;
            if expiry > now {
                if existing.body_hash != request.body_hash {
                    return Err(IdempotencyError::KeyReused);
                }
                let status = StatusCode::from_u16(existing.status_code as u16)
                    .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?;
                let body = existing
                    .response_json
                    .map(|raw| serde_json::from_str(&raw))
                    .transpose()
                    .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?
                    .unwrap_or(Value::Null);
                let operation_id = existing
                    .operation_id
                    .map(|raw| Uuid::parse_str(&raw))
                    .transpose()
                    .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?;
                return Ok(Some(IdempotencyOutcome {
                    response: StoredResponse {
                        status,
                        body,
                        operation_id,
                    },
                    created: false,
                }));
            }

            transaction.execute(
                "DELETE FROM idempotency_records
                  WHERE device_id = ?1 AND method = ?2 AND path = ?3 AND idempotency_key = ?4",
                rusqlite::params![
                    request.device_id.to_string(),
                    request.method,
                    request.path,
                    request.key.to_string(),
                ],
            )?;
        }

        Ok(None)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_operation(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
        jobs: &JobService,
        kind: &str,
        resource_id: Option<&str>,
        input_json: &str,
    ) -> Result<IdempotencyOutcome, IdempotencyError> {
        self.execute(conn, request, |transaction| {
            let operation_id = jobs.create(
                transaction,
                kind,
                request.device_id,
                resource_id,
                input_json,
            )?;
            let row = jobs
                .get(transaction, operation_id)?
                .ok_or(store::StoreError::NotFound("operation"))?;
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: serde_json::to_value(row)
                    .map_err(|error| store::StoreError::Sqlite(error.to_string()))?,
                operation_id: Some(operation_id),
            })
        })
    }

    /// Commit operation, accepted audit record and replay response together; audit failure rolls back all three.
    #[allow(clippy::too_many_arguments)]
    pub fn create_operation_audited(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
        jobs: &JobService,
        kind: &str,
        resource_id: Option<&str>,
        input_json: &str,
        actor_role: &str,
        source_route: &str,
        audit_resource: Option<&str>,
        audit_details: &Value,
    ) -> Result<IdempotencyOutcome, IdempotencyError> {
        self.execute(conn, request, |transaction| {
            let operation_id = jobs.create(
                transaction,
                kind,
                request.device_id,
                resource_id,
                input_json,
            )?;
            crate::audit::append(
                transaction,
                self.clock.as_ref(),
                &crate::audit::AuditDraft {
                    actor_device_id: Some(request.device_id),
                    actor_role: Some(actor_role),
                    source_route,
                    action: kind,
                    resource: audit_resource,
                    result: "accepted",
                    operation_id: Some(operation_id),
                    request_id: request.request_id,
                    details: audit_details,
                },
            )?;
            let row = jobs
                .get(transaction, operation_id)?
                .ok_or(store::StoreError::NotFound("operation"))?;
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: serde_json::to_value(row)
                    .map_err(|error| store::StoreError::Sqlite(error.to_string()))?,
                operation_id: Some(operation_id),
            })
        })
    }

    /// Disable cancellation when accepted host power effects have no safe cancellation or rollback boundary.
    #[allow(clippy::too_many_arguments)]
    pub fn create_noncancellable_operation_audited(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
        jobs: &JobService,
        kind: &str,
        resource_id: Option<&str>,
        input_json: &str,
        actor_role: &str,
        source_route: &str,
        audit_resource: Option<&str>,
        audit_details: &Value,
    ) -> Result<IdempotencyOutcome, IdempotencyError> {
        self.execute(conn, request, |transaction| {
            let operation_id = jobs.create(
                transaction,
                kind,
                request.device_id,
                resource_id,
                input_json,
            )?;
            transaction.execute(
                "UPDATE operations SET cancellable = 0 WHERE id = ?1",
                [operation_id.to_string()],
            )?;
            crate::audit::append(
                transaction,
                self.clock.as_ref(),
                &crate::audit::AuditDraft {
                    actor_device_id: Some(request.device_id),
                    actor_role: Some(actor_role),
                    source_route,
                    action: kind,
                    resource: audit_resource,
                    result: "accepted",
                    operation_id: Some(operation_id),
                    request_id: request.request_id,
                    details: audit_details,
                },
            )?;
            let row = jobs
                .get(transaction, operation_id)?
                .ok_or(store::StoreError::NotFound("operation"))?;
            Ok(StoredResponse {
                status: StatusCode::ACCEPTED,
                body: serde_json::to_value(row)
                    .map_err(|error| store::StoreError::Sqlite(error.to_string()))?,
                operation_id: Some(operation_id),
            })
        })
    }

    /// Replace provisional acceptance and operation state atomically when synchronous admission fails so retries receive the actual first result.
    pub fn replace_response<F>(
        &self,
        conn: &mut rusqlite::Connection,
        request: &IdempotencyRequest,
        response: &StoredResponse,
        update: F,
    ) -> Result<(), IdempotencyError>
    where
        F: FnOnce(&rusqlite::Transaction<'_>) -> Result<(), store::StoreError>,
    {
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        update(&transaction)?;
        let changed = transaction.execute(
            "UPDATE idempotency_records
                SET status_code = ?1, response_json = ?2, operation_id = ?3
              WHERE device_id = ?4 AND method = ?5 AND path = ?6
                AND idempotency_key = ?7 AND body_hash = ?8",
            rusqlite::params![
                i64::from(response.status.as_u16()),
                serde_json::to_string(&response.body)
                    .map_err(|error| IdempotencyError::Corrupt(error.to_string()))?,
                response.operation_id.map(|id| id.to_string()),
                request.device_id.to_string(),
                request.method,
                request.path,
                request.key.to_string(),
                request.body_hash,
            ],
        )?;
        if changed != 1 {
            return Err(IdempotencyError::Corrupt(
                "response record disappeared before admission completed".into(),
            ));
        }
        transaction.commit()?;
        Ok(())
    }
}

fn format_utc(timestamp: time::OffsetDateTime) -> String {
    timestamp
        .to_offset(time::UtcOffset::UTC)
        .format(&Rfc3339)
        .expect("UTC timestamps always format as RFC3339")
}

pub fn json_response(outcome: &IdempotencyOutcome) -> (StatusCode, Json<Value>) {
    (outcome.response.status, Json(outcome.response.body.clone()))
}

#[cfg(test)]
#[path = "idempotency/tests.rs"]
mod tests;

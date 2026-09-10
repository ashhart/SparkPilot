//! Persist durable operation state before side effects and retain idempotent worker stages.

use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::Duration as StdDuration;
use uuid::Uuid;

use crate::clock::{UtcClock, system_clock};
use crate::store;

mod events;
mod executor;
mod lease;
mod recovery;
mod types;

use events::OperationEvents;
pub use executor::{WorkerPool, WorkerPoolMetrics, WorkerSlot};
pub use lease::{LeaseError, OperationLease};
pub use recovery::{RecoveryAction, RecoveryReport};
pub use types::{CancellationRegistry, LeaseConfig, OperationState};

/// Who holds a lease, and at which fence; both are checked on every write the holder makes.
#[derive(Debug, Clone, Copy)]
struct LeaseHolder<'a> {
    owner: &'a str,
    fence: i64,
}

#[derive(Debug, Clone)]
pub struct JobService {
    cancellations: Arc<Mutex<CancellationRegistry>>,
    clock: Arc<dyn UtcClock>,
    daemon_id: Arc<str>,
    events: Option<OperationEvents>,
    lease: LeaseConfig,
    workers: Arc<WorkerPool>,
}

impl Default for JobService {
    fn default() -> Self {
        Self::with_clock(system_clock())
    }
}

impl JobService {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_clock(clock: Arc<dyn UtcClock>) -> Self {
        Self::with_clock_and_lease(clock, LeaseConfig::default())
    }

    pub fn with_clock_and_lease(clock: Arc<dyn UtcClock>, lease: LeaseConfig) -> Self {
        Self {
            cancellations: Arc::new(Mutex::new(CancellationRegistry::new())),
            clock,
            daemon_id: Arc::from(Uuid::new_v4().to_string()),
            events: None,
            workers: WorkerPool::new(lease.worker_count),
            lease,
        }
    }

    /// Publish PLAN §60.2's operation family; without a bus the service still persists every transition.
    pub fn with_events(mut self, bus: crate::events::EventBus, node_id: &str) -> Self {
        self.events = Some(OperationEvents {
            bus,
            node_id: Arc::from(node_id),
        });
        self
    }

    /// The bounded operation executor backing every leased worker.
    pub fn workers(&self) -> &Arc<WorkerPool> {
        &self.workers
    }

    /// Saturation metrics for the status surface.
    pub fn worker_metrics(&self) -> WorkerPoolMetrics {
        self.workers.metrics()
    }

    pub fn cancellation_registry(&self) -> Arc<Mutex<CancellationRegistry>> {
        self.cancellations.clone()
    }

    pub fn daemon_id(&self) -> &str {
        &self.daemon_id
    }

    pub(crate) fn now_rfc3339(&self) -> String {
        self.clock.now_rfc3339()
    }

    /// Keep operation and dependent-service deadlines on the same UTC clock.
    pub(crate) fn now(&self) -> time::OffsetDateTime {
        self.clock.now()
    }

    /// Persist state before any side effect; returns the operation id.
    pub fn create(
        &self,
        conn: &Connection,
        kind: &str,
        actor_device_id: Uuid,
        resource_id: Option<&str>,
        input_json: &str,
    ) -> Result<Uuid, store::StoreError> {
        self.create_with_id(
            conn,
            Uuid::new_v4(),
            kind,
            actor_device_id,
            resource_id,
            input_json,
        )
    }

    /// Create an operation whose id an idempotency record already fixed, announcing it like any other.
    pub fn create_with_id(
        &self,
        conn: &Connection,
        id: Uuid,
        kind: &str,
        actor_device_id: Uuid,
        resource_id: Option<&str>,
        input_json: &str,
    ) -> Result<Uuid, store::StoreError> {
        conn.execute(
            "INSERT INTO operations
                (id, kind, state, actor_device_id, resource_id, progress, stage,
                 created_at, updated_at, started_at, completed_at, error_code,
                 result_json, cancellable, lease_owner, lease_expires_at, input_json)
             VALUES (?1, ?2, 'queued', ?3, ?4, NULL, 'pending',
                     ?5, ?5, NULL, NULL, NULL, NULL, 1, NULL, NULL, ?6)",
            rusqlite::params![
                id.to_string(),
                kind,
                actor_device_id.to_string(),
                resource_id,
                self.now_rfc3339(),
                input_json,
            ],
        )?;
        self.publish_operation(conn, id, "operation.created", "info");
        Ok(id)
    }

    pub fn acquire_lease(
        &self,
        database: Arc<Mutex<Connection>>,
        id: Uuid,
    ) -> Result<OperationLease, LeaseError> {
        let owner = format!("{}:{}", self.daemon_id, Uuid::new_v4());
        let fence;
        {
            let mut conn = database.lock();
            let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let current = transaction
                .query_row(
                    "SELECT state, lease_expires_at, lease_owner, lease_fence FROM operations WHERE id = ?1",
                    [id.to_string()],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, Option<String>>(1)?,
                            row.get::<_, Option<String>>(2)?,
                            row.get::<_, i64>(3)?,
                        ))
                    },
                )
                .map_err(store::StoreError::from)?;
            if !matches!(current.0.as_str(), "queued" | "running") {
                return Err(LeaseError::Held);
            }
            let live = current
                .1
                .as_deref()
                .and_then(parse_rfc3339)
                .is_some_and(|expiry| expiry > self.clock.now());
            // Expiry is not proof a worker stopped: explicit recovery must settle or reconcile it before any replay.
            if live || current.2.is_some() {
                return Err(LeaseError::Held);
            }
            // Every acquisition raises the fence, so an earlier holder can no longer write anything.
            fence = current.3.saturating_add(1);
            let now = self.clock.now();
            let expiry = format_utc(now + time::Duration::seconds(self.lease.lease_seconds));
            transaction.execute(
                "UPDATE operations
                    SET state = 'running', started_at = COALESCE(started_at, ?1),
                        updated_at = ?1, lease_owner = ?2, lease_expires_at = ?3,
                        lease_fence = ?5
                  WHERE id = ?4",
                rusqlite::params![format_utc(now), owner, expiry, id.to_string(), fence],
            )?;
            transaction.commit()?;
        }

        Ok(OperationLease::new(
            self.clone(),
            database,
            id,
            owner,
            fence,
        ))
    }

    /// Admit a bounded worker slot before claiming a lease so saturation needs no ownership rollback.
    pub fn spawn_leased<F>(
        &self,
        database: Arc<Mutex<Connection>>,
        operation_id: Uuid,
        worker: F,
    ) -> Result<(), LeaseError>
    where
        F: FnOnce(OperationLease) + Send + 'static,
    {
        let slot = self
            .workers
            .try_admit()
            .ok_or(LeaseError::Overloaded(self.lease.worker_count))?;
        let lease = self.acquire_lease(database, operation_id)?;
        std::thread::spawn(move || {
            // Held for the whole worker, released on every exit path.
            let _slot = slot;
            if lease.is_cancelled() {
                lease.settle_failed("OPERATION_CANCELLED");
                return;
            }
            worker(lease);
        });
        Ok(())
    }

    /// Count already-leased workers against the same executor capacity.
    pub fn spawn_with_lease<F>(&self, worker: F) -> Result<(), LeaseError>
    where
        F: FnOnce() + Send + 'static,
    {
        let slot = self
            .workers
            .try_admit()
            .ok_or(LeaseError::Overloaded(self.lease.worker_count))?;
        std::thread::spawn(move || {
            let _slot = slot;
            worker();
        });
        Ok(())
    }

    fn renew_owned(
        &self,
        conn: &Connection,
        id: Uuid,
        owner: &str,
        fence: i64,
    ) -> Result<(), LeaseError> {
        let now = self.clock.now();
        let expiry = format_utc(now + time::Duration::seconds(self.lease.lease_seconds));
        let changed = conn.execute(
            "UPDATE operations SET lease_expires_at = ?1, updated_at = ?2
              WHERE id = ?3 AND lease_owner = ?4 AND lease_fence = ?5
                AND state IN ('running', 'cancelling')",
            rusqlite::params![expiry, format_utc(now), id.to_string(), owner, fence],
        )?;
        if changed == 1 {
            Ok(())
        } else {
            Err(LeaseError::Lost)
        }
    }

    fn finish_owned(
        &self,
        conn: &mut Connection,
        id: Uuid,
        holder: LeaseHolder<'_>,
        requested_state: &str,
        error_code: Option<&str>,
        result: Option<&serde_json::Value>,
    ) -> Result<(), LeaseError> {
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state: Option<String> = transaction
            .query_row(
                "SELECT state FROM operations
                  WHERE id = ?1 AND lease_owner = ?2 AND lease_fence = ?3",
                rusqlite::params![id.to_string(), holder.owner, holder.fence],
                |row| row.get(0),
            )
            .optional()?;
        let Some(state) = state else {
            drop(transaction);
            self.record_lost_lease(conn, id, holder.fence, requested_state, error_code);
            return Err(LeaseError::Lost);
        };
        let cancelled = state == "cancelling";
        let final_state = if cancelled {
            "cancelled"
        } else {
            requested_state
        };
        let final_error = if cancelled {
            Some("OPERATION_CANCELLED")
        } else {
            error_code
        };
        let result_json = if cancelled {
            None
        } else {
            result.map(serde_json::Value::to_string)
        };
        let now = self.now_rfc3339();
        transaction.execute(
            "UPDATE operations
                SET state = ?1, completed_at = ?2, updated_at = ?2,
                    error_code = ?3, result_json = ?4, cancellable = 0,
                    lease_owner = NULL, lease_expires_at = NULL
              WHERE id = ?5 AND lease_owner = ?6 AND lease_fence = ?7",
            rusqlite::params![
                final_state,
                now,
                final_error,
                result_json,
                id.to_string(),
                holder.owner,
                holder.fence,
            ],
        )?;
        crate::audit::append_operation_terminal(
            &transaction,
            self.clock.as_ref(),
            id,
            final_state,
            final_error,
        )?;
        transaction.commit()?;
        self.cancellations.lock().clear(&id);
        let (event_type, severity) = Self::terminal_event(final_state);
        self.publish_operation(conn, id, event_type, severity);
        Ok(())
    }

    pub fn set_stage(
        &self,
        conn: &Connection,
        id: Uuid,
        stage: &str,
        progress: Option<f64>,
    ) -> Result<(), store::StoreError> {
        let changed = conn.execute(
            "UPDATE operations SET stage = ?1, progress = ?2, updated_at = ?3
              WHERE id = ?4 AND lease_owner IS NULL",
            rusqlite::params![stage, progress, self.now_rfc3339(), id.to_string()],
        )?;
        if changed == 1 {
            self.publish_operation(conn, id, "operation.progress", "info");
            Ok(())
        } else {
            Err(store::StoreError::Sqlite(
                "leased operation requires its OperationLease capability".into(),
            ))
        }
    }

    pub fn succeed(
        &self,
        conn: &Connection,
        id: Uuid,
        result: &serde_json::Value,
    ) -> Result<(), store::StoreError> {
        self.finish(conn, id, "succeeded", None, Some(result))
    }

    pub fn fail(
        &self,
        conn: &Connection,
        id: Uuid,
        error_code: &str,
    ) -> Result<(), store::StoreError> {
        self.finish(conn, id, "failed", Some(error_code), None)
    }

    pub fn cancelled(
        &self,
        conn: &Connection,
        id: Uuid,
        error_code: &str,
    ) -> Result<(), store::StoreError> {
        self.finish(conn, id, "cancelled", Some(error_code), None)
    }

    pub fn cancel_requested(&self, conn: &Connection, id: Uuid) -> Result<bool, store::StoreError> {
        let changed = self.persist_cancellation_request(conn, id)?;
        if changed {
            self.signal_cancellation(id);
        }
        Ok(changed)
    }

    /// Persist cancellation inside the replay transaction and signal workers only after commit.
    pub fn persist_cancellation_request(
        &self,
        conn: &Connection,
        id: Uuid,
    ) -> Result<bool, store::StoreError> {
        let changed = conn.execute(
            "UPDATE operations SET state = 'cancelling', updated_at = ?1
              WHERE id = ?2 AND state NOT IN ('succeeded','failed','cancelled')",
            rusqlite::params![self.now_rfc3339(), id.to_string()],
        )?;
        Ok(changed > 0)
    }

    pub fn signal_cancellation(&self, id: Uuid) {
        self.cancellations.lock().request(id);
    }

    pub fn worker_cancelled(&self, id: Uuid) -> bool {
        let registry = self.cancellations.lock();
        registry.is_cancelled(&id)
    }

    /// Fail expired workers without replaying side effects, leaving live leases and queued work untouched.
    pub fn reap_expired_leases(&self, conn: &mut Connection) -> Result<usize, store::StoreError> {
        self.recovery().reap_expired_leases(conn)
    }

    /// Recover only operations with durable reconciliation evidence; fail unsafe restart mutations explicitly.
    pub fn recover_abandoned(
        &self,
        conn: &mut Connection,
    ) -> Result<(RecoveryReport, Vec<RecoveryAction>), store::StoreError> {
        self.recovery().recover_abandoned(conn)
    }

    fn finish(
        &self,
        conn: &Connection,
        id: Uuid,
        state: &str,
        error_code: Option<&str>,
        result: Option<&serde_json::Value>,
    ) -> Result<(), store::StoreError> {
        if conn.is_autocommit() {
            // Commit synchronous terminal state and its audit record atomically.
            let transaction = conn.unchecked_transaction()?;
            self.finish_in_transaction(&transaction, id, state, error_code, result)?;
            transaction.commit()?;
        } else {
            // Join caller-owned idempotency transactions instead of nesting a transaction.
            self.finish_in_transaction(conn, id, state, error_code, result)?;
        }
        self.cancellations.lock().clear(&id);
        let (event_type, severity) = Self::terminal_event(state);
        self.publish_operation(conn, id, event_type, severity);
        Ok(())
    }

    fn finish_in_transaction(
        &self,
        conn: &Connection,
        id: Uuid,
        state: &str,
        error_code: Option<&str>,
        result: Option<&serde_json::Value>,
    ) -> Result<(), store::StoreError> {
        let result_json = result.map(|r| r.to_string());
        let changed = conn.execute(
            "UPDATE operations
                SET state = ?1, completed_at = ?2, updated_at = ?2,
                    error_code = ?3, result_json = ?4,
                    lease_owner = NULL, lease_expires_at = NULL
              WHERE id = ?5 AND lease_owner IS NULL
                AND state NOT IN ('succeeded','failed','cancelled')",
            rusqlite::params![
                state,
                self.now_rfc3339(),
                error_code,
                result_json,
                id.to_string()
            ],
        )?;
        if changed != 1 {
            return Err(store::StoreError::Sqlite(
                "leased operation requires its OperationLease capability".into(),
            ));
        }
        crate::audit::append_operation_terminal(conn, self.clock.as_ref(), id, state, error_code)?;
        Ok(())
    }

    /// Read a visible operation row (for the REST surface).
    pub fn get(
        &self,
        conn: &Connection,
        id: Uuid,
    ) -> Result<Option<store::OperationRow>, store::StoreError> {
        store::operation_row(conn, id)
    }

    pub fn list(&self, conn: &Connection) -> Result<Vec<store::OperationRow>, store::StoreError> {
        store::operation_rows(conn)
    }

    /// A visibility-scoped, cursor-paginated page of operations (§58.6).
    pub fn list_page(
        &self,
        conn: &Connection,
        viewer: Option<Uuid>,
        after: Option<(&str, &str)>,
        limit: usize,
    ) -> Result<(Vec<store::OperationRow>, bool), store::StoreError> {
        store::operation_rows_page(conn, viewer, after, limit)
    }

    /// Whether a live lease is on this operation now; a caller that could not resume it asks before settling it.
    pub fn is_leased(&self, conn: &Connection, id: Uuid) -> bool {
        conn.query_row(
            "SELECT lease_expires_at FROM operations WHERE id = ?1 AND lease_owner IS NOT NULL",
            [id.to_string()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten()
        .and_then(|value| parse_rfc3339(&value))
        .is_some_and(|expiry| expiry > self.clock.now())
    }

    fn recovery(&self) -> recovery::Recovery<'_> {
        recovery::Recovery {
            clock: &self.clock,
            cancellations: &self.cancellations,
            daemon_id: &self.daemon_id,
        }
    }
}

fn parse_rfc3339(value: &str) -> Option<time::OffsetDateTime> {
    time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339).ok()
}

fn format_utc(value: time::OffsetDateTime) -> String {
    value
        .to_offset(time::UtcOffset::UTC)
        .format(&time::format_description::well_known::Rfc3339)
        .expect("UTC timestamps always format as RFC3339")
}

#[cfg(test)]
#[path = "jobs/tests.rs"]
mod tests;

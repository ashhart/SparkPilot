//! Own scoped pool policy and durable reservations without content storage; uncertain execution retains its capacity charge.

use crate::{
    auth::Principal,
    crypto::sha256_hex,
    engine::{EngineError, EngineInstance},
    idempotency::IdempotencyRequest,
    pool_contracts::*,
    state::AppState,
};

use axum::{Json, http::StatusCode};

use parking_lot::Mutex;

use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};

use serde_json::{Value, json};

use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use uuid::Uuid;

pub struct PoolService {
    pub generation: Uuid,
    initialized: Mutex<bool>,
    leases: Mutex<HashMap<Uuid, Instant>>,
    grants: Mutex<HashMap<Uuid, Instant>>,
}

impl Default for PoolService {
    fn default() -> Self {
        Self {
            generation: Uuid::new_v4(),
            initialized: Mutex::new(false),
            leases: Mutex::new(HashMap::new()),
            grants: Mutex::new(HashMap::new()),
        }
    }
}

impl PoolService {
    pub fn initialize(&self, conn: &mut Connection, now: i64) -> Result<(), PoolError> {
        let mut initialized = self.initialized.lock();
        if *initialized {
            return Ok(());
        }
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute("UPDATE inference_reservations SET state='expired',reason='not_dispatched',updated_at=?1 WHERE state='reserved'", [now])?;
        tx.execute("UPDATE inference_reservations SET state='outcome_unknown',reason='node_restarted',updated_at=?1 WHERE state IN ('accepted','cancel_requested')", [now])?;
        tx.commit()?;
        *initialized = true;
        Ok(())
    }

    pub fn prepare(&self, state: &AppState) -> Result<(), PoolError> {
        let mut conn = database(state)?.lock();
        let now = state.clock.now().unix_timestamp();
        self.initialize(&mut conn, now)?;
        let previous: Option<i64> = conn
            .query_row(
                "SELECT observed_at_milliseconds FROM inference_pool_clock WHERE singleton=1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        let now_milliseconds = (state.clock.now().unix_timestamp_nanos() / 1_000_000) as i64;
        if previous.is_some_and(|v| now_milliseconds < v) {
            return refuse("POOL_CLOCK_REGRESSED");
        }
        conn.execute("INSERT INTO inference_pool_clock VALUES(1,?1) ON CONFLICT(singleton) DO UPDATE SET observed_at_milliseconds=MAX(observed_at_milliseconds,excluded.observed_at_milliseconds)", [now_milliseconds])?;
        self.sweep(&conn, now)?;
        Ok(())
    }

    fn sweep(&self, conn: &Connection, now: i64) -> Result<(), PoolError> {
        let mut leases = self.leases.lock();
        let expired: Vec<_> = leases
            .iter()
            .filter(|(_, deadline)| Instant::now() >= **deadline)
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            conn.execute("UPDATE inference_reservations SET state='expired',reason='not_dispatched',updated_at=?1 WHERE reservation_id=?2 AND state='reserved'", params![now,id.to_string()])?;
            leases.remove(&id);
        }
        conn.execute("UPDATE inference_reservations SET state='expired',reason='not_dispatched',updated_at=?1 WHERE state='reserved' AND expires_at<=?1", [now])?;
        conn.execute(
            "DELETE FROM inference_pool_previews WHERE expires_at<=?1",
            [now],
        )?;
        conn.execute("DELETE FROM inference_router_grants WHERE (revoked=1 OR expires_at<=?1) AND NOT EXISTS(SELECT 1 FROM inference_reservations r WHERE r.grant_id=inference_router_grants.grant_id)",[now])?;
        self.grants
            .lock()
            .retain(|_, deadline| Instant::now() < *deadline);
        // Reject stale unseen UUIDv7 ids before admission, retain unknown charged work and prune only retired receipt history.
        conn.execute("DELETE FROM inference_reservations WHERE created_at<?1 AND (capacity_released=1 OR state IN ('succeeded','failed','cancelled','expired'))", [now - RESERVATION_RECEIPT_SECONDS])?;
        conn.execute("DELETE FROM inference_pool_mutations WHERE path LIKE '/api/v1/inference/reservations%' AND created_at<?1", [now - RESERVATION_RECEIPT_SECONDS])?;
        conn.execute(
            "DELETE FROM inference_pool_mutations WHERE created_at<?1",
            [now - 86_400],
        )?;
        Ok(())
    }

    pub fn preview(
        &self,
        state: &AppState,
        actor: Uuid,
        request: PoolPolicyPreviewRequest,
        key: &IdempotencyRequest,
    ) -> Result<PoolPolicyPreview, PoolError> {
        self.prepare(state)?;
        validate_policy(&request.policy, state.identity.node_id())?;
        let mut conn = database(state)?.lock();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        eligible_owner(&tx, actor)?;
        if let Some(value) = lookup_mutation(&tx, key)? {
            return Ok(serde_json::from_value(value)?);
        }
        let conn = &tx;
        for id in &request.policy.caller_device_ids {
            eligible_device(conn, *id)?;
        }
        for id in &request.policy.router_device_ids {
            eligible_router(conn, *id)?;
        }
        let revision = policy_revision(conn, request.policy.pool_id)?;
        if revision != request.expected_revision || request.policy.revision != revision + 1 {
            return refuse("POOL_POLICY_CHANGED");
        }
        let count: u32 =
            conn.query_row("SELECT count(*) FROM inference_pool_previews", [], |r| {
                r.get(0)
            })?;
        if count >= 128 {
            return refuse("POOL_PREVIEW_LIMIT");
        }
        let result = PoolPolicyPreview {
            preview_id: Uuid::new_v4(),
            expected_revision: revision,
            expires_at: state.clock.now().unix_timestamp() + 60,
            policy: request.policy,
        };
        conn.execute("INSERT INTO inference_pool_previews(preview_id,pool_id,actor_device_id,expected_revision,policy_json,expires_at) VALUES(?1,?2,?3,?4,?5,?6)", params![result.preview_id.to_string(),result.policy.pool_id.to_string(),actor.to_string(),revision,serde_json::to_string(&result.policy)?,result.expires_at])?;
        store_mutation(
            conn,
            key,
            &serde_json::to_value(&result)?,
            state.clock.now().unix_timestamp(),
        )?;
        tx.commit()?;
        Ok(result)
    }

    pub fn apply(
        conn: &Connection,
        state: &AppState,
        actor: Uuid,
        preview_id: Uuid,
    ) -> Result<Value, PoolError> {
        policy_mutations::apply(conn, state, actor, preview_id)
    }

    pub fn create_grant(
        conn: &Connection,
        state: &AppState,
        actor: Uuid,
        scope: CreateRouterGrantRequest,
    ) -> Result<Value, PoolError> {
        policy_mutations::create_grant(conn, state, actor, scope)
    }

    pub fn revoke(conn: &Connection, grant_id: Uuid) -> Result<Value, PoolError> {
        policy_mutations::revoke(conn, grant_id)
    }

    fn authorize(
        &self,
        conn: &Connection,
        state: &AppState,
        principal: &Principal,
        grant_id: Uuid,
        action: RouterAction,
        new_work: bool,
    ) -> Result<(RouterGrant, InferencePoolPolicy), PoolError> {
        let row: Option<(String, bool)> = conn
            .query_row(
                "SELECT grant_json,revoked FROM inference_router_grants WHERE grant_id=?1",
                [grant_id.to_string()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((raw, revoked)) = row else {
            return refuse("POOL_GRANT_FORBIDDEN");
        };
        let grant: RouterGrant = serde_json::from_str(&raw)?;
        eligible_router(conn, principal.device_id)?;
        if new_work {
            eligible_device(conn, grant.scope.caller_device_id)?;
        }
        let policy = load_policy(conn, grant.scope.pool_id)?;
        if grant.audience_node_id != state.identity.node_id()
            || grant.scope.router_device_id != principal.device_id
            || !grant.scope.actions.contains(&action)
        {
            return refuse("POOL_GRANT_FORBIDDEN");
        }
        if new_work {
            eligible_owner(conn, grant.issued_by_device_id)?;
            let now = state.clock.now().unix_timestamp();
            let mut deadlines = self.grants.lock();
            let deadline = deadlines.entry(grant_id).or_insert_with(|| {
                Instant::now()
                    + Duration::from_secs(
                        grant
                            .expires_at
                            .saturating_sub(now)
                            .clamp(0, MAX_GRANT_SECONDS) as u64,
                    )
            });
            if revoked
                || grant.expires_at <= now
                || now < grant.issued_at
                || Instant::now() >= *deadline
                || policy.paused
                || policy.revision != grant.scope.policy_revision
                || !policy.router_device_ids.contains(&principal.device_id)
                || !policy
                    .caller_device_ids
                    .contains(&grant.scope.caller_device_id)
            {
                return refuse("POOL_GRANT_FORBIDDEN");
            }
        }
        Ok((grant, policy))
    }

    pub fn reserve(
        &self,
        state: &AppState,
        principal: &Principal,
        idempotency: &IdempotencyRequest,
        request: ReserveInferenceRequest,
    ) -> Result<AdmissionReservation, PoolError> {
        self.prepare(state)?;
        if !valid_digest(&request.deployment_id)
            || !valid_digest(&request.request_sha256)
            || request.request_bytes == 0
            || request.request_bytes as usize > MAX_REQUEST_BYTES
            || request.context_budget == 0
            || request.output_budget == 0
            || request.lease_seconds == 0
            || u64::from(request.lease_seconds) > MAX_LEASE_SECONDS
            || request.required_capabilities.is_empty()
            || request
                .required_capabilities
                .iter()
                .any(|v| !matches!(v.as_str(), "text_chat" | "streaming"))
        {
            return refuse("POOL_REQUEST_INVALID");
        }
        let binding = digest(&request)?;
        // Permit recovery without a current model or live grant only when the paired router proves the original scope.
        {
            let mut conn = database(state)?.lock();
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            self.authorize(
                &tx,
                state,
                principal,
                request.grant_id,
                RouterAction::Reserve,
                false,
            )?;
            if let Some(value) = lookup_mutation(&tx, idempotency)? {
                return Ok(serde_json::from_value(value)?);
            }
            let old: Option<(String,String)> = tx.query_row("SELECT reservation_id,binding_sha256 FROM inference_reservations WHERE attempt_id=?1", [request.attempt_id.to_string()], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
            if let Some((id, old_binding)) = old {
                if old_binding != binding {
                    return refuse("POOL_ATTEMPT_REUSED");
                }
                let value = read_reservation(
                    &tx,
                    state.identity.node_id(),
                    Uuid::parse_str(&id)
                        .map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?,
                )?;
                store_mutation(
                    &tx,
                    idempotency,
                    &serde_json::to_value(&value)?,
                    state.clock.now().unix_timestamp(),
                )?;
                tx.commit()?;
                return Ok(value);
            }
        }
        let request_created_at = validate_request_age(
            request.request_id,
            (state.clock.now().unix_timestamp_nanos() / 1_000_000) as i64,
        )?;
        let manager = state
            .engine
            .manager
            .as_ref()
            .ok_or(PoolError::Refused("POOL_ENGINE_UNAVAILABLE"))?;
        let result = manager.with_pool_admission(|instance, direct_active| {
            let live = deployment(instance, &state.config.runtime_version)?;
            if live.deployment_id != request.deployment_id
                || request.context_budget.saturating_add(u64::from(request.output_budget)) > live.context_length {
                return refuse("POOL_DEPLOYMENT_CHANGED");
            }
            check_resource_state(state, instance)?;
            let mut conn = database(state)?.lock();
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let (grant, policy) = self.authorize(
                &tx, state, principal, request.grant_id, RouterAction::Reserve, true,
            )?;
            if let Some(value) = lookup_mutation(&tx, idempotency)? {
                return Ok(serde_json::from_value(value)?);
            }
            if request.pool_id != grant.scope.pool_id
                || request.caller_device_id != grant.scope.caller_device_id
                || request.policy_revision != policy.revision
                || !grant.scope.deployment_ids.contains(&request.deployment_id) {
                return refuse("POOL_GRANT_FORBIDDEN");
            }
            let old: Option<(String, String)> = tx.query_row(
                "SELECT reservation_id,binding_sha256 FROM inference_reservations WHERE attempt_id=?1",
                [request.attempt_id.to_string()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            ).optional()?;
            if let Some((id, old_binding)) = old {
                if old_binding != binding { return refuse("POOL_ATTEMPT_REUSED"); }
                let value = read_reservation(
                    &tx, state.identity.node_id(),
                    Uuid::parse_str(&id).map_err(|_| PoolError::Refused("POOL_STORAGE_UNAVAILABLE"))?,
                )?;
                store_mutation(&tx, idempotency, &serde_json::to_value(&value)?, state.clock.now().unix_timestamp())?;
                tx.commit()?;
                return Ok(value);
            }
            let duplicate: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM inference_reservations
                 WHERE caller_device_id=?1 AND request_id=?2
                 AND NOT (state IN ('cancelled','expired') AND reason='not_dispatched'))",
                params![request.caller_device_id.to_string(), request.request_id.to_string()],
                |r| r.get(0),
            )?;
            if duplicate { return refuse("POOL_REQUEST_ALREADY_ASSIGNED"); }
            let all: u32 = tx.query_row("SELECT count(*) FROM inference_reservations", [], |r| r.get(0))?;
            if all >= MAX_RESERVATIONS as u32 { return refuse("POOL_RECEIPT_LIMIT"); }
            let total = engine_capacity_charge(&tx)?.unwrap_or(0);
            let buffered: u64 = tx.query_row(
                &format!("SELECT COALESCE(sum(request_bytes),0) FROM inference_reservations
                          WHERE state IN {CHARGED} AND capacity_released=0"),
                [], |r| r.get(0),
            )?;
            if buffered.saturating_add(u64::from(request.request_bytes)) > policy.max_buffered_bytes.min(64 * 1024 * 1024) {
                return refuse("POOL_BUFFER_BUDGET_EXCEEDED");
            }
            let per_pool: u32 = tx.query_row(
                &format!("SELECT count(*) FROM inference_reservations
                          WHERE pool_id=?1 AND state IN {CHARGED} AND capacity_released=0"),
                [request.pool_id.to_string()], |r| r.get(0),
            )?;
            let per_caller: u32 = tx.query_row(
                &format!("SELECT count(*) FROM inference_reservations
                          WHERE caller_device_id=?1 AND state IN {CHARGED} AND capacity_released=0"),
                [request.caller_device_id.to_string()], |r| r.get(0),
            )?;
            if total.saturating_add(direct_active) >= live.max_sequences
                || per_pool >= policy.max_concurrent_requests
                || per_caller >= policy.max_concurrent_per_caller {
                return refuse("POOL_CAPACITY_BUSY");
            }
            let id = Uuid::new_v4();
            let now = state.clock.now().unix_timestamp();
            let expires = (now + i64::from(request.lease_seconds)).min(grant.expires_at);
            tx.execute(
                "INSERT INTO inference_reservations(
                    reservation_id,request_id,attempt_id,grant_id,pool_id,router_device_id,
                    caller_device_id,deployment_id,request_sha256,request_bytes,binding_sha256,
                    policy_revision,context_budget,output_budget,state,created_at,expires_at,
                    updated_at,engine_instance_id,request_created_at_milliseconds)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?16,?10,?11,?12,?13,'reserved',?14,?15,?14,?17,?18)",
                params![
                    id.to_string(), request.request_id.to_string(), request.attempt_id.to_string(),
                    request.grant_id.to_string(), request.pool_id.to_string(), principal.device_id.to_string(),
                    request.caller_device_id.to_string(), request.deployment_id, request.request_sha256,
                    binding, request.policy_revision, request.context_budget, request.output_budget,
                    now, expires, request.request_bytes, instance.instance_id.to_string(), request_created_at,
                ],
            )?;
            let result = read_reservation(&tx, state.identity.node_id(), id)?;
            store_mutation(&tx, idempotency, &serde_json::to_value(&result)?, now)?;
            tx.commit()?;
            self.leases.lock().insert(id, Instant::now() + Duration::from_secs(expires.saturating_sub(now) as u64));
            Ok(result)
        })?;
        Ok(result)
    }

    pub fn status(
        &self,
        state: &AppState,
        principal: &Principal,
        id: Uuid,
        cancel: bool,
        key: Option<&IdempotencyRequest>,
    ) -> Result<AdmissionReservation, PoolError> {
        self.prepare(state)?;
        let mut conn = database(state)?.lock();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let grant_id = reservation_grant(&tx, id)?;
        self.authorize(
            &tx,
            state,
            principal,
            grant_id,
            if cancel {
                RouterAction::Cancel
            } else {
                RouterAction::Status
            },
            false,
        )?;
        if let Some(key) = key
            && let Some(value) = lookup_mutation(&tx, key)?
        {
            return Ok(serde_json::from_value(value)?);
        }
        if cancel {
            tx.execute("UPDATE inference_reservations SET state=CASE WHEN state='reserved' THEN 'cancelled' WHEN state='accepted' THEN 'cancel_requested' ELSE state END,reason=CASE WHEN state='reserved' THEN 'not_dispatched' ELSE reason END,updated_at=?1 WHERE reservation_id=?2",params![state.clock.now().unix_timestamp(),id.to_string()])?;
        }
        let result = read_reservation(&tx, state.identity.node_id(), id)?;
        if let Some(key) = key {
            store_mutation(
                &tx,
                key,
                &serde_json::to_value(&result)?,
                state.clock.now().unix_timestamp(),
            )?;
        }
        tx.commit()?;
        Ok(result)
    }

    pub fn accept(
        &self,
        state: &AppState,
        principal: &Principal,
        idempotency: &IdempotencyRequest,
        id: Uuid,
        body: &[u8],
        instance: &EngineInstance,
    ) -> Result<AdmissionReservation, PoolError> {
        let live = deployment(instance, &state.config.runtime_version)?;
        check_resource_state(state, instance)?;
        let mut conn = database(state)?.lock();
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let grant_id = reservation_grant(&tx, id)?;
        let (grant, policy) =
            self.authorize(&tx, state, principal, grant_id, RouterAction::Execute, true)?;
        if lookup_mutation(&tx, idempotency)?.is_some() {
            return refuse("POOL_ATTEMPT_ALREADY_DISPATCHED");
        }
        let reservation = read_reservation(&tx, state.identity.node_id(), id)?;
        if reservation.state != ReservationState::Reserved {
            return refuse("POOL_ATTEMPT_ALREADY_DISPATCHED");
        }
        if reservation.expires_at <= state.clock.now().unix_timestamp()
            || self
                .leases
                .lock()
                .get(&id)
                .is_none_or(|d| Instant::now() >= *d)
        {
            return refuse("POOL_RESERVATION_EXPIRED");
        }
        if reservation.deployment_id != live.deployment_id
            || reservation.policy_revision != policy.revision
            || !grant.scope.deployment_ids.contains(&live.deployment_id)
        {
            return refuse("POOL_DEPLOYMENT_CHANGED");
        }
        let (expected,size):(String,u32)=tx.query_row("SELECT request_sha256,request_bytes FROM inference_reservations WHERE reservation_id=?1",[id.to_string()],|r|Ok((r.get(0)?,r.get(1)?)))?;
        if sha256_hex(body) != expected || body.len() != size as usize {
            return refuse("POOL_REQUEST_DIGEST_MISMATCH");
        }
        validate_execution_body(
            body,
            &reservation,
            &instance.served_name,
            &instance.model_id,
        )?;
        tx.execute("UPDATE inference_reservations SET state='accepted',updated_at=?1 WHERE reservation_id=?2 AND state='reserved'",params![state.clock.now().unix_timestamp(),id.to_string()])?;
        let result = read_reservation(&tx, state.identity.node_id(), id)?;
        store_mutation(
            &tx,
            idempotency,
            &serde_json::to_value(&result)?,
            state.clock.now().unix_timestamp(),
        )?;
        tx.commit()?;
        self.leases.lock().remove(&id);
        Ok(result)
    }

    /// Called only by the node worker, never from router-supplied completion.
    pub fn finish(
        &self,
        state: &AppState,
        id: Uuid,
        confirmed: bool,
        success: bool,
    ) -> Result<(), PoolError> {
        policy_mutations::finish(state, id, confirmed, success)
    }
}

#[cfg(test)]
#[path = "pool/tests.rs"]
mod tests;

mod policy_mutations;

mod policy_store;
pub(crate) use policy_store::refuse;
pub use policy_store::{
    CHARGED, PoolError, database, digest, eligible_device, eligible_owner, eligible_router,
    load_policy, lookup_mutation, policy_revision, read_reservation, store_mutation, valid_digest,
    validate_request_age,
};
use policy_store::{reservation_grant, validate_policy};

mod housekeeping;
pub use housekeeping::spawn_housekeeping;

mod deployment;
pub(crate) use deployment::{
    check_resource_state, durable_work_outstanding, engine_capacity_charge,
    release_stopped_instance,
};
pub use deployment::{deployment, validate_execution_body};

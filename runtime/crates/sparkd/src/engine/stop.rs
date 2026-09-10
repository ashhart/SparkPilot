use super::*;

pub(super) struct StopFlow<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) backend: &'a dyn EngineBackend,
    pub(super) effects: effects::Effects<'a>,
    pub(super) capacity: capacity::Capacity<'a>,
    pub(super) drain_grace: Duration,
}

impl StopFlow<'_> {
    pub(super) async fn unload_worker(
        &self,
        lease: crate::jobs::OperationLease,
        operation_id: Uuid,
        instance: EngineInstance,
        force: bool,
    ) {
        let model_id = instance.model_id.clone();
        if lease.is_cancelled() {
            let mut core = self.inner.lock();
            core.transitioning = false;
            core.state = EngineState::Ready;
            drop(core);
            lease.settle_failed("OPERATION_CANCELLED");
            return;
        }
        self.effects.emit_event(
            Some(operation_id),
            "engine.draining",
            "info",
            json!({ "model": model_id }),
        );
        let _ = self
            .effects
            .persist_instance_state(&instance, "draining", None);
        let _ = lease.set_stage("draining", Some(0.15));
        if !force {
            drain_graced(self.inner, self.drain_grace).await;
        }

        self.inner.lock().state = EngineState::Stopping;
        let _ = self
            .effects
            .persist_instance_state(&instance, "unloading", None);
        let _ = lease.set_stage("stopping", Some(0.50));
        let stop_result = self.backend.stop(&instance, force).await;
        let running = self.backend.is_running(&instance).await;
        let _ = lease.set_stage("verifying_memory_recovery", Some(0.80));
        let recovered = self.capacity.wait_for_memory_recovery(&instance).await;

        let mut core = self.inner.lock();
        core.transitioning = false;
        // Judge stop by container evidence and report memory recovery separately in the event and operation result.
        let stopped = container_stopped(stop_result.is_ok(), running);
        if !stopped {
            let reason = match (&stop_result, running) {
                (Err(e), _) => format!("container stop failed: {e}"),
                (_, true) => "container still running after stop".to_owned(),
                _ => "unload failed".to_owned(),
            };
            // Keep the exact failed instance so a signed retry repeats stop verification.
            core.instance = Some(instance.clone());
            core.active_requests = 0;
            core.pool_active_requests = 0;
            core.state = EngineState::Failed;
            self.effects.guard_set_active(None);
            let _ = self
                .effects
                .persist_instance_state(&instance, "failed", Some(&reason));
            drop(core);
            lease.settle_failed(&reason);
            self.effects.emit_event(
                Some(operation_id),
                "model.unload_failed",
                "critical",
                json!({ "model": model_id, "memory_recovered": recovered }),
            );
            return;
        }
        core.instance = None;
        core.last_unload = Some(self.capacity.unload_evidence(&instance, recovered));
        core.active_requests = 0;
        core.pool_active_requests = 0;
        core.state = EngineState::Unloaded;
        self.effects.guard_set_active(None);
        let _ = self
            .effects
            .persist_instance_state(&instance, "stopped", None);
        drop(core);
        let _ = lease.set_stage("unloaded", Some(1.0));
        lease.settle_succeeded(&json!({
            "unload": "verified",
            "model": model_id,
            "memory_recovered": recovered,
        }));
        self.effects.emit_event(
            Some(operation_id),
            "model.unloaded",
            "info",
            json!({ "model": model_id, "memory_recovered": recovered }),
        );
    }

    pub(super) async fn idle_stop_worker(&self, instance: EngineInstance) {
        let model_id = instance.model_id.clone();
        let profile_id = instance.profile_id.clone();
        let stop_result = self.backend.stop(&instance, false).await;
        let running = self.backend.is_running(&instance).await;
        let recovered = self.capacity.wait_for_memory_recovery(&instance).await;
        let mut core = self.inner.lock();
        core.transitioning = false;
        core.active_requests = 0;
        core.pool_active_requests = 0;
        // Judge stop by container evidence; reclaimable page cache can delay baseline memory recovery.
        let stopped = container_stopped(stop_result.is_ok(), running);
        if stopped {
            core.instance = None;
            core.last_unload = Some(self.capacity.unload_evidence(&instance, recovered));
            core.state = EngineState::Unloaded;
            let _ = self
                .effects
                .persist_instance_state(&instance, "stopped", None);
        } else {
            core.instance = Some(instance.clone());
            core.state = EngineState::Failed;
            let _ = self.effects.persist_instance_state(
                &instance,
                "failed",
                Some("IDLE_UNLOAD_FAILED"),
            );
        }
        core.idle_generation = core.idle_generation.wrapping_add(1);
        self.effects.guard_set_active(None);
        let state = core.state;
        drop(core);
        self.effects.emit_event(
            None,
            if stopped {
                "model.idle.unloaded"
            } else {
                "model.idle.unload_failed"
            },
            if stopped { "info" } else { "critical" },
            json!({
                "model": model_id,
                "profile": profile_id,
                "stopped": stopped,
                "memory_recovered": recovered,
                "state": state.as_str(),
            }),
        );
    }

    pub(super) async fn guard_stop_worker(&self, instance: EngineInstance, force: bool) {
        let model_id = instance.model_id.clone();
        let stop_result = self.backend.stop(&instance, force).await;
        let running = self.backend.is_running(&instance).await;
        let recovered = self.capacity.wait_for_memory_recovery(&instance).await;
        let mut core = self.inner.lock();
        core.transitioning = false;
        core.active_requests = 0;
        core.pool_active_requests = 0;
        // Judge stop by container evidence because reclaimable page cache can retain weights after the process exits.
        let stopped = container_stopped(stop_result.is_ok(), running);
        if stopped {
            core.instance = None;
            core.last_unload = Some(self.capacity.unload_evidence(&instance, recovered));
            core.state = EngineState::Unloaded;
            let _ = self
                .effects
                .persist_instance_state(&instance, "stopped", None);
        } else {
            core.instance = Some(instance.clone());
            core.state = EngineState::Failed;
            let _ = self.effects.persist_instance_state(
                &instance,
                "failed",
                Some("MEMORY_GUARD_STOP_FAILED"),
            );
        }
        let ok = stopped && recovered;
        self.effects.guard_set_active(None);
        let state = core.state;
        drop(core);
        self.effects.emit_event(
            None,
            if ok {
                "model.guard.stopped"
            } else {
                "model.guard.stop_failed"
            },
            if ok { "info" } else { "critical" },
            json!({
                "model": model_id,
                "force": force,
                "reason": "memory_guard",
                "stopped": stopped,
                "memory_recovered": recovered,
                "state": state.as_str(),
            }),
        );
    }
}

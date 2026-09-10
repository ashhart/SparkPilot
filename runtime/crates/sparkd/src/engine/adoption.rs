use super::*;

pub(super) struct Adoption<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) backend: &'a dyn EngineBackend,
    pub(super) jobs: &'a JobService,
    pub(super) db: &'a Arc<Mutex<rusqlite::Connection>>,
    pub(super) models_root: &'a std::path::Path,
    pub(super) telemetry: &'a dyn SystemMonitor,
    pub(super) effects: effects::Effects<'a>,
}

impl Adoption<'_> {
    /// Adopt the exact running vLLM container id and port just reverified by the HTTP preview boundary.
    pub(super) fn prepare(
        &self,
        operation_id: Uuid,
        recipe: &ModelRecipe,
        profile_id: &str,
        workload_id: String,
        host_port: u16,
    ) -> Result<(crate::jobs::OperationLease, EngineInstance), EngineError> {
        let Some(profile) = recipe
            .profiles
            .iter()
            .find(|profile| profile.id == profile_id)
        else {
            return Err(EngineError::Invalid(format!(
                "profile {profile_id} not in recipe {}",
                recipe.id()
            )));
        };
        let record = crate::store::model_row(&self.db.lock(), recipe.id())
            .map_err(|error| EngineError::Invalid(error.to_string()))?
            .ok_or_else(|| EngineError::Invalid("model row missing".into()))?;
        if record.install_state != "installed" || record.source_revision != recipe.source.revision {
            return Err(EngineError::Invalid(
                "the exact model revision is not installed".into(),
            ));
        }
        let mut core = self.inner.lock();
        if core.transitioning || core.instance.is_some() {
            return Err(EngineError::Active(
                "another engine is active or transitioning".into(),
            ));
        }
        let lease = self
            .jobs
            .acquire_lease(self.db.clone(), operation_id)
            .map_err(|error| EngineError::Active(error.to_string()))?;
        let instance = EngineInstance {
            instance_id: Uuid::new_v4(),
            model_id: recipe.id().to_owned(),
            profile_id: profile_id.to_owned(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: snapshot_path(self.models_root, recipe),
            internal_port: host_port,
            // Exact adoption uses the immutable image default environment, so there is no external bearer secret or proxy Authorization.
            api_key: String::new(),
            external_workload_id: Some(workload_id),
            recipe: recipe.clone(),
            profile: profile.clone(),
            memory_baseline_bytes: self.telemetry.system().unified_memory_available_bytes,
            // Adopted container: we did not launch it, so we cannot set a cgroup cap.
            memory_limit_bytes: None,
            gpu_memory_utilisation_milli: declared_utilisation_milli(profile),
        };
        core.transitioning = true;
        core.state = EngineState::HealthCheck;
        drop(core);

        Ok((lease, instance))
    }

    pub(super) async fn adopt_worker(
        &self,
        lease: crate::jobs::OperationLease,
        operation_id: Uuid,
        instance: EngineInstance,
    ) {
        let _ = lease.set_stage("verifying_external_workload", Some(0.3));
        let result = async {
            if lease.is_cancelled() {
                return Err("OPERATION_CANCELLED".to_owned());
            }
            if !self.backend.health(&instance).await.unwrap_or(false) {
                return Err("external workload health check failed".to_owned());
            }
            let names = self
                .backend
                .list_model_names(&instance)
                .await
                .map_err(|error| format!("external model probe failed: {error}"))?;
            if names != [instance.served_name.clone()] {
                return Err("external workload model alias changed".to_owned());
            }
            // Persist ownership only after proving health, routing and later stop against the exact immutable container id.
            self.effects
                .persist_instance_state(&instance, "ready", None)?;
            Ok::<(), String>(())
        }
        .await;

        let mut core = self.inner.lock();
        core.transitioning = false;
        match result {
            Ok(()) => {
                core.instance = Some(instance.clone());
                core.state = EngineState::Ready;
                drop(core);
                self.effects
                    .guard_set_active(Some(crate::guard::ActiveProfile {
                        model_id: instance.model_id.clone(),
                        profile_id: instance.profile_id.clone(),
                    }));
                let _ = lease.set_stage("ready", Some(1.0));
                lease.settle_succeeded(&json!({
                    "model_id": &instance.model_id,
                    "workload_id": instance.external_workload_id.as_deref(),
                    "ownership": "spark_managed",
                }));
                self.effects.emit_event(
                    Some(operation_id),
                    "workload.adopted",
                    "info",
                    json!({ "model": instance.model_id }),
                );
            }
            Err(error) => {
                core.state = EngineState::Failed;
                drop(core);
                let code = if error == "OPERATION_CANCELLED" {
                    "OPERATION_CANCELLED"
                } else {
                    "WORKLOAD_ADOPTION_FAILED"
                };
                lease.settle_failed(code);
                self.effects.emit_event(
                    Some(operation_id),
                    "workload.adoption_failed",
                    "warning",
                    json!({ "code": code }),
                );
            }
        }
    }

    /// Relinquish an adopted workload without container commands; Spark-launched instances cannot use this path.
    pub(super) fn validate_relinquish_adopted(
        &self,
        workload_id: &str,
    ) -> Result<String, EngineError> {
        let core = self.inner.lock();
        let Some(instance) = core.instance.as_ref() else {
            return Err(EngineError::NotLoaded);
        };
        if core.transitioning {
            return Err(EngineError::NotReady);
        }
        if instance.external_workload_id.as_deref() != Some(workload_id) {
            return Err(EngineError::Invalid(
                "the workload is not an adopted active engine".into(),
            ));
        }
        if core.active_requests != 0 {
            return Err(EngineError::Active(
                "wait for active requests before relinquishing ownership".into(),
            ));
        }
        Ok(instance.instance_id.to_string())
    }

    /// Reserve admission across the ownership-row transaction and in-memory transition.
    pub(super) fn begin_relinquish_adopted(
        &self,
        workload_id: &str,
    ) -> Result<String, EngineError> {
        let mut core = self.inner.lock();
        let Some(instance) = core.instance.as_ref() else {
            return Err(EngineError::NotLoaded);
        };
        if core.transitioning || core.active_requests != 0 {
            return Err(EngineError::NotReady);
        }
        if instance.external_workload_id.as_deref() != Some(workload_id) {
            return Err(EngineError::Invalid(
                "the workload is not an adopted active engine".into(),
            ));
        }
        let instance_id = instance.instance_id.to_string();
        core.transitioning = true;
        Ok(instance_id)
    }

    pub(super) fn abort_relinquish_adopted(&self, workload_id: &str) {
        let mut core = self.inner.lock();
        if core
            .instance
            .as_ref()
            .and_then(|instance| instance.external_workload_id.as_deref())
            == Some(workload_id)
        {
            core.transitioning = false;
        }
    }

    pub(super) fn finish_relinquish_adopted(&self, workload_id: &str) -> Result<(), EngineError> {
        let mut core = self.inner.lock();
        let matches = core
            .instance
            .as_ref()
            .and_then(|instance| instance.external_workload_id.as_deref())
            == Some(workload_id);
        if !matches || !core.transitioning || core.active_requests != 0 {
            return Err(EngineError::NotReady);
        }
        core.instance = None;
        core.state = EngineState::Unloaded;
        core.transitioning = false;
        drop(core);
        self.effects.guard_set_active(None);
        Ok(())
    }
}

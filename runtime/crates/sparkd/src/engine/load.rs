use super::*;

pub(super) struct LoadFlow<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) backend: &'a dyn EngineBackend,
    pub(super) jobs: &'a JobService,
    pub(super) db: &'a Arc<Mutex<rusqlite::Connection>>,
    pub(super) models_root: &'a std::path::Path,
    pub(super) telemetry: &'a dyn SystemMonitor,
    pub(super) effects: effects::Effects<'a>,
    pub(super) capacity: capacity::Capacity<'a>,
    pub(super) health_check_timeout: Duration,
    pub(super) drain_grace: Duration,
}

impl LoadFlow<'_> {
    /// Queue the handler-owned durable load operation; replacing the active model requires replace_active.
    pub(super) fn prepare(
        &self,
        operation_id: Uuid,
        recipe: &ModelRecipe,
        profile_id: &str,
        replace_active: bool,
    ) -> Result<
        (
            crate::jobs::OperationLease,
            EngineInstance,
            Option<EngineInstance>,
        ),
        EngineError,
    > {
        let Some(profile) = recipe.profiles.iter().find(|p| p.id == profile_id) else {
            return Err(EngineError::Invalid(format!(
                "profile {profile_id} not in recipe {}",
                recipe.id()
            )));
        };
        if profile.expected_peak_bytes == 0 {
            return Err(EngineError::Invalid(
                "profile has zero expected peak".into(),
            ));
        }
        let baseline = self.capacity.admit(recipe, profile, replace_active)?;

        let record = crate::store::model_row(&self.db.lock(), recipe.id())
            .map_err(|e| EngineError::Invalid(e.to_string()))?;
        let Some(record) = record else {
            return Err(EngineError::Invalid("model row missing".into()));
        };
        if record.install_state != "installed" {
            return Err(EngineError::Invalid(format!(
                "model {} is not installed (state {})",
                recipe.id(),
                record.install_state
            )));
        }
        // Require the installed revision before stopping any outgoing engine, so the mounted snapshot was actually downloaded.
        if record.source_revision != recipe.source.revision {
            return Err(EngineError::Invalid(format!(
                "model {} is installed at revision {} but the recipe names {}",
                recipe.id(),
                record.source_revision,
                recipe.source.revision
            )));
        }
        let snapshot = snapshot_path(self.models_root, recipe);

        let mut core = self.inner.lock();
        if core.transitioning {
            return Err(EngineError::Active(
                "another engine transition is in progress".into(),
            ));
        }
        let replaced = match &core.instance {
            Some(active) => {
                let same = active.model_id == recipe.id();
                if !replace_active {
                    return Err(EngineError::Active(format!(
                        "engine is serving {}; pass replace_active=true to {}",
                        active.model_id,
                        if same { "reload it" } else { "replace it" }
                    )));
                }
                Some(active.clone())
            }
            None => None,
        };

        let instance_id = Uuid::new_v4();
        // Cap the container at available memory minus system reserve so a runaway load cannot exhaust the host.
        let system_reserve = self.capacity.system_reserve_bytes(recipe);
        let memory_limit_bytes = baseline
            .checked_sub(system_reserve)
            .filter(|budget| *budget > 0)
            .map(|budget| {
                if recipe.uses_qwen38_preparation() {
                    budget.min(90 * 1024 * 1024 * 1024)
                } else {
                    budget
                }
            });
        let instance = EngineInstance {
            instance_id,
            model_id: recipe.id().to_owned(),
            profile_id: profile_id.to_owned(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: snapshot,
            internal_port: derived_internal_port(instance_id),
            api_key: random_api_key(),
            external_workload_id: None,
            recipe: recipe.clone(),
            profile: profile.clone(),
            memory_baseline_bytes: baseline,
            memory_limit_bytes,
            gpu_memory_utilisation_milli: recipe.launch_utilisation_milli(
                profile,
                self.telemetry.system().unified_memory_total_bytes,
            ),
        };

        let lease = self
            .jobs
            .acquire_lease(self.db.clone(), operation_id)
            .map_err(|error| EngineError::Active(error.to_string()))?;

        core.transitioning = true;
        core.state = EngineState::Preflighting;
        drop(core);

        Ok((lease, instance, replaced))
    }

    pub(super) async fn load_worker(
        &self,
        lease: crate::jobs::OperationLease,
        operation_id: Uuid,
        mut instance: EngineInstance,
        replaced: Option<EngineInstance>,
        schedule_idle_watch: impl Fn(),
    ) {
        let model_id = instance.model_id.clone();
        let profile_id = instance.profile_id.clone();
        if lease.is_cancelled() {
            let mut core = self.inner.lock();
            core.transitioning = false;
            // Cancellation leaves the outgoing replacement engine Ready; a cancelled fresh load is Unloaded.
            core.state = if replaced.is_some() {
                EngineState::Ready
            } else {
                EngineState::Unloaded
            };
            drop(core);
            lease.settle_failed("OPERATION_CANCELLED");
            return;
        }
        let mut rollback_candidate = None;
        let outcome = self
            .try_load(&lease, &mut instance, replaced, &mut rollback_candidate)
            .await;
        let (success, outcome_text) = match &outcome {
            Ok(_) => (true, "ready".to_owned()),
            Err(e) => (false, e.clone()),
        };
        if success {
            let port = match &outcome {
                Ok((port, _)) => *port,
                Err(_) => unreachable!(),
            };
            instance.internal_port = port;
            let reserved = outcome.as_ref().map(|(_, reserved)| *reserved).unwrap_or(0);
            let observed_memory_bytes = instance
                .memory_baseline_bytes
                .saturating_sub(self.telemetry.system().unified_memory_available_bytes)
                .saturating_sub(reserved);
            if observed_memory_bytes > 0
                && let Err(error) = crate::guard::record_profile_peak(
                    &self.db.lock(),
                    &model_id,
                    &profile_id,
                    observed_memory_bytes,
                    &crate::guard::recipe_environment(&instance.recipe),
                )
            {
                tracing::warn!(%error, "failed to record observed profile memory");
            }
            let mut core = self.inner.lock();
            core.transitioning = false;
            core.instance = Some(instance);
            core.last_unload = None;
            core.state = EngineState::Ready;
            core.last_ttft_ms = None;
            core.active_requests = 0;
            core.pool_active_requests = 0;
            core.last_activity = Instant::now();
            core.idle_generation = core.idle_generation.wrapping_add(1);
            self.effects
                .guard_set_active(Some(crate::guard::ActiveProfile {
                    model_id: model_id.clone(),
                    profile_id: profile_id.clone(),
                }));
            drop(core);
            schedule_idle_watch();
            let _ = lease
                .succeed(&json!({ "load": "ready", "model": model_id, "profile": profile_id }));
            self.effects.emit_event(
                Some(operation_id),
                "model.ready",
                "info",
                json!({ "model": model_id, "profile": profile_id, "detail": outcome_text }),
            );
        } else {
            // Clean up a failed candidate and restore the exact previous signed recipe/profile when replacement stopped it.
            {
                let mut core = self.inner.lock();
                core.state = EngineState::Stopping;
            }
            let cleanup = self.backend.stop(&instance, true).await;
            if cleanup.is_err() {
                tracing::warn!(instance = %instance.instance_id, "force stop after failed load");
            }
            let _ = self
                .effects
                .persist_instance_state(&instance, "failed", Some(&outcome_text));
            let mut restored = None;
            if let Some(mut candidate) = rollback_candidate {
                let stage = if candidate.relaunch {
                    "restoring_previous_engine"
                } else {
                    "verifying_previous_engine"
                };
                let _ = lease.set_stage(stage, Some(0.85));
                let restore_result = if candidate.relaunch {
                    self.restore_previous_engine(&mut candidate.instance).await
                } else {
                    self.verify_engine(&candidate.instance).await
                };
                match restore_result {
                    Ok(()) => restored = Some(candidate.instance),
                    Err(error) => {
                        let _ = self.effects.persist_instance_state(
                            &candidate.instance,
                            "failed",
                            Some("ROLLBACK_RESTORE_FAILED"),
                        );
                        tracing::error!(%error, "failed to restore previous engine");
                    }
                }
            }
            let mut core = self.inner.lock();
            core.instance = restored.clone();
            core.active_requests = 0;
            core.pool_active_requests = 0;
            core.state = if restored.is_some() {
                EngineState::Ready
            } else {
                EngineState::Failed
            };
            core.last_activity = Instant::now();
            core.idle_generation = core.idle_generation.wrapping_add(1);
            core.transitioning = false;
            self.effects
                .guard_set_active(
                    restored
                        .as_ref()
                        .map(|previous| crate::guard::ActiveProfile {
                            model_id: previous.model_id.clone(),
                            profile_id: previous.profile_id.clone(),
                        }),
                );
            if let Some(previous) = restored.as_ref() {
                let _ = self.effects.persist_instance_state(previous, "ready", None);
            }
            drop(core);
            if restored.is_some() {
                schedule_idle_watch();
            }
            // Owners see the stable code; the full outcome stays on the event and the instance record.
            lease.settle_failed(launch_failure_code(&outcome_text));
            self.effects.emit_event(
                Some(operation_id),
                "model.load_failed",
                "error",
                json!({
                    "model": model_id,
                    "profile": profile_id,
                    "detail": outcome_text,
                    "previous_engine_restored": restored.is_some(),
                }),
            );
        }
    }

    pub(super) async fn try_load(
        &self,
        lease: &crate::jobs::OperationLease,
        instance: &mut EngineInstance,
        replaced: Option<EngineInstance>,
        rollback_candidate: &mut Option<RollbackCandidate>,
    ) -> Result<(u16, u64), String> {
        if let Some(old) = replaced {
            self.inner.lock().state = EngineState::Draining;
            let _ = lease.set_stage("draining_previous", Some(0.10));
            drain_graced(self.inner, self.drain_grace).await;
            let _ = lease.set_stage("stopping_previous", Some(0.20));
            if let Err(error) = self.backend.stop(&old, true).await {
                if self.backend.is_running(&old).await {
                    *rollback_candidate = Some(RollbackCandidate {
                        instance: old,
                        relaunch: false,
                    });
                } else {
                    let _ = self.effects.persist_instance_state(
                        &old,
                        "failed",
                        Some("REPLACEMENT_STOP_FAILED"),
                    );
                }
                return Err(format!("failed to replace active engine: {error}"));
            }
            if self.backend.is_running(&old).await {
                *rollback_candidate = Some(RollbackCandidate {
                    instance: old,
                    relaunch: false,
                });
                return Err("outgoing engine still running after stop".into());
            }
            if !self.capacity.wait_for_memory_recovery(&old).await {
                let _ = self.effects.persist_instance_state(
                    &old,
                    "failed",
                    Some("REPLACEMENT_MEMORY_RECOVERY_FAILED"),
                );
                return Err("outgoing engine memory did not recover after stop".into());
            }
            *rollback_candidate = Some(RollbackCandidate {
                instance: old.clone(),
                relaunch: true,
            });
            self.effects.persist_instance_state(&old, "stopped", None)?;

            // After the outgoing stop, replace projected recovery with actual memory and repeat canonical admission.
            let recovered_available = self.telemetry.system().unified_memory_available_bytes;
            let recovered_admission = self
                .capacity
                .admission_evidence_with_available(
                    &instance.recipe,
                    &instance.profile,
                    recovered_available,
                )
                .map_err(|error| error.message())?;
            if !recovered_admission.decision.is_allowed() {
                return Err("incoming model no longer fits after outgoing memory recovery".into());
            }
            instance.memory_baseline_bytes = recovered_available;
        }

        if lease.is_cancelled() {
            return Err("OPERATION_CANCELLED".into());
        }

        self.effects
            .persist_instance_state(instance, "loading", None)?;

        // Image pull exposes no measurable progress; None clears the previous stage fraction.
        let _ = lease.set_stage("preparing_engine_image", None);
        self.backend
            .prepare(instance)
            .await
            .map_err(|e| format!("engine image preparation failed: {e}"))?;

        if lease.is_cancelled() {
            return Err("OPERATION_CANCELLED".into());
        }

        // Recheck memory after a slow image pull and refresh the baseline and cgroup cap before launching.
        let available_now = self.telemetry.system().unified_memory_available_bytes;
        let admission_now = self
            .capacity
            .admission_evidence_with_available(&instance.recipe, &instance.profile, available_now)
            .map_err(|error| error.message())?;
        if !admission_now.decision.is_allowed() {
            return Err("model no longer fits the available memory after the image pull".into());
        }
        instance.memory_baseline_bytes = available_now;
        let system_reserve = self.capacity.system_reserve_bytes(&instance.recipe);
        instance.memory_limit_bytes = available_now
            .checked_sub(system_reserve)
            .filter(|b| *b > 0)
            .map(|budget| {
                if instance.recipe.uses_qwen38_preparation() {
                    budget.min(90 * 1024 * 1024 * 1024)
                } else {
                    budget
                }
            });

        self.inner.lock().state = EngineState::Starting;
        let _ = if instance.recipe.uses_qwen38_preparation() {
            lease.set_stage("preparing_offload_table", None)
        } else {
            lease.set_stage("starting", Some(0.55))
        };

        let (port, host_reserved) = self
            .backend
            .launch_accounted(instance)
            .await
            .map_err(|e| format!("container launch failed: {e}"))?;
        // The existing system reserve covers this measured VM-policy reservation, never model pages.
        let host_reserved = host_reserved.min(system_reserve);
        // Use the actual backend-bound listener for every later probe and stop, including collision fallback.
        instance.internal_port = port;

        self.inner.lock().state = EngineState::HealthCheck;
        // Estimate warmup progress from memory within the health-stage band; only successful probes can mark Ready.
        const HEALTH_STAGE_START: f64 = 0.70;
        const HEALTH_STAGE_CEILING: f64 = 0.84;
        let expected_peak = instance.recipe.profile_reservation_bytes(&instance.profile);
        let baseline = instance.memory_baseline_bytes.saturating_sub(host_reserved);
        let mut reported = HEALTH_STAGE_START;
        let _ = lease.set_stage("health_check", Some(reported));
        let deadline = tokio::time::Instant::now()
            + if instance.recipe.uses_qwen38_preparation() {
                self.health_check_timeout.max(Duration::from_secs(1800))
            } else {
                self.health_check_timeout
            };
        let healthy = loop {
            if lease.is_cancelled() {
                return Err("OPERATION_CANCELLED".into());
            }
            if self.backend.health(instance).await.unwrap_or(false) {
                break true;
            }
            if self.backend.has_exited(instance).await {
                return Err("model container exited during startup".into());
            }
            if expected_peak > 0 {
                let available = self.telemetry.system().unified_memory_available_bytes;
                let taken = baseline.saturating_sub(available) as f64;
                let fraction = (taken / expected_peak as f64).clamp(0.0, 1.0);
                let candidate =
                    HEALTH_STAGE_START + fraction * (HEALTH_STAGE_CEILING - HEALTH_STAGE_START);
                // Keep reported progress monotonic when loading buffers are freed.
                if candidate > reported + 0.005 {
                    reported = candidate;
                    let _ = lease.set_stage("health_check", Some(reported));
                }
            }
            let now = tokio::time::Instant::now();
            if now >= deadline {
                break false;
            }
            tokio::time::sleep(HEALTH_POLL_INTERVAL.min(deadline - now)).await;
        };
        if !healthy {
            return Err("model health check timed out".into());
        }

        let names = self
            .backend
            .list_model_names(instance)
            .await
            .map_err(|e| format!("model probe failed: {e}"))?;
        if !names.iter().any(|n| n == &instance.served_name) {
            return Err(format!(
                "served model name {} not present (saw {names:?})",
                instance.served_name
            ));
        }

        let _ = lease.set_stage("serving_probe", Some(0.85));
        self.backend
            .probe_completion(instance)
            .await
            .map_err(|e| format!("serving probe failed: {e}"))?;

        self.inner.lock().state = EngineState::Ready;
        self.effects
            .persist_instance_state(instance, "ready", None)?;
        let _ = lease.set_stage("ready", Some(1.0));
        Ok((port, host_reserved))
    }

    pub(super) async fn restore_previous_engine(
        &self,
        instance: &mut EngineInstance,
    ) -> Result<(), String> {
        self.effects
            .persist_instance_state(instance, "loading", None)?;
        self.backend
            .prepare(instance)
            .await
            .map_err(|error| format!("previous engine image preparation failed: {error}"))?;
        let port = self
            .backend
            .launch(instance)
            .await
            .map_err(|error| format!("previous engine launch failed: {error}"))?;
        instance.internal_port = port;

        self.verify_engine(instance).await?;
        self.effects
            .persist_instance_state(instance, "ready", None)?;
        Ok(())
    }

    pub(super) async fn verify_engine(&self, instance: &EngineInstance) -> Result<(), String> {
        let deadline = tokio::time::Instant::now()
            + if instance.recipe.uses_qwen38_preparation() {
                self.health_check_timeout.max(Duration::from_secs(1800))
            } else {
                self.health_check_timeout
            };
        loop {
            if self.backend.health(instance).await.unwrap_or(false) {
                break;
            }
            let now = tokio::time::Instant::now();
            if now >= deadline {
                let _ = self.backend.stop(instance, true).await;
                return Err("previous engine health check timed out".into());
            }
            tokio::time::sleep(HEALTH_POLL_INTERVAL.min(deadline - now)).await;
        }

        let names = match self.backend.list_model_names(instance).await {
            Ok(names) => names,
            Err(error) => {
                let _ = self.backend.stop(instance, true).await;
                return Err(format!("previous engine model probe failed: {error}"));
            }
        };
        if !names.iter().any(|name| name == &instance.served_name) {
            let _ = self.backend.stop(instance, true).await;
            return Err(format!(
                "previous served model name {} not present (saw {names:?})",
                instance.served_name
            ));
        }
        if let Err(error) = self.backend.probe_completion(instance).await {
            let _ = self.backend.stop(instance, true).await;
            return Err(format!("previous engine serving probe failed: {error}"));
        }
        Ok(())
    }
}

pub(super) fn snapshot_path(models_root: &std::path::Path, recipe: &ModelRecipe) -> PathBuf {
    crate::model_paths::snapshot_path(models_root, recipe.id(), &recipe.source.revision)
        .unwrap_or_else(|_| models_root.join("snapshots").join(".invalid"))
}

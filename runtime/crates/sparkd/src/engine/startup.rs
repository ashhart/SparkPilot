use super::*;

pub(super) struct Startup<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) backend: &'a dyn EngineBackend,
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) node_id: &'a str,
    pub(super) models_root: &'a std::path::Path,
    pub(super) telemetry: &'a dyn SystemMonitor,
    pub(super) effects: effects::Effects<'a>,
}

impl Startup<'_> {
    /// Remove surviving secret-bearing managed containers on restart; inventory reconciliation can recover credential-free adopted workloads.
    pub(super) async fn reconcile_startup(&self) -> Result<usize, EngineError> {
        self.reconcile_startup_inner(None).await
    }

    /// Recover one exact adopted workload while retaining secret-bearing managed-container cleanup.
    pub(super) async fn reconcile_startup_with_inventory(
        &self,
        inventory: &crate::models::ModelInventory,
    ) -> Result<usize, EngineError> {
        self.reconcile_startup_inner(Some(inventory)).await
    }

    pub(super) async fn reconcile_startup_inner(
        &self,
        inventory: Option<&crate::models::ModelInventory>,
    ) -> Result<usize, EngineError> {
        struct PersistedInstance {
            raw_id: String,
            model_id: String,
            profile_id: String,
            container_id: Option<String>,
            internal_port: i64,
            adopted: bool,
        }

        let persisted = {
            let conn = self.db.lock();
            let mut statement = conn
                .prepare(
                    "SELECT id, model_id, profile_id, container_id, internal_port, metadata_json FROM inference_instances WHERE node_id = ?1 AND state != 'stopped' ORDER BY started_at, id",
                )
                .map_err(|error| EngineError::Backend(error.to_string()))?;
            let rows = statement
                .query_map([&self.node_id], |row| {
                    let id: String = row.get(0)?;
                    let model_id: String = row.get(1)?;
                    let profile_id: String = row.get(2)?;
                    let container_id: Option<String> = row.get(3)?;
                    let internal_port: i64 = row.get(4)?;
                    let metadata: String = row.get(5)?;
                    let adopted = serde_json::from_str::<Value>(&metadata)
                        .ok()
                        .and_then(|value| {
                            value
                                .get("ownership_origin")
                                .and_then(Value::as_str)
                                .map(|origin| origin == "external_adoption")
                        })
                        .unwrap_or(false);
                    Ok(PersistedInstance {
                        raw_id: id,
                        model_id,
                        profile_id,
                        container_id,
                        internal_port,
                        adopted,
                    })
                })
                .map_err(|error| EngineError::Backend(error.to_string()))?;
            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|error| EngineError::Backend(error.to_string()))?
        };

        for row in &persisted {
            let instance_id = Uuid::parse_str(&row.raw_id).map_err(|error| {
                EngineError::Backend(format!("invalid persisted instance: {error}"))
            })?;
            if row.adopted {
                if self
                    .recover_adopted_instance(
                        instance_id,
                        &row.model_id,
                        &row.profile_id,
                        row.container_id.as_deref(),
                        row.internal_port,
                        inventory,
                    )
                    .await?
                {
                    continue;
                }
                // Losing adoption proof drops ownership without sending any lifecycle command to the external container.
                self.db
                    .lock()
                    .execute(
                        "UPDATE inference_instances SET state = 'stopped', stopped_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), failure_code = 'ADOPTED_WORKLOAD_RECOVERY_FAILED' WHERE id = ?1",
                        [&row.raw_id],
                    )
                    .map_err(|error| EngineError::Backend(error.to_string()))?;
                continue;
            }
            if let Err(error) = self.backend.reconcile_instance(instance_id, None).await {
                let _ = self.db.lock().execute(
                    "UPDATE inference_instances SET state = 'failed', failure_code = ?2 WHERE id = ?1",
                    rusqlite::params![row.raw_id, "STARTUP_RECONCILIATION_FAILED"],
                );
                return Err(EngineError::Backend(format!(
                    "startup engine reconciliation failed for {instance_id}: {error}"
                )));
            }
            let mut conn = self.db.lock();
            let tx = conn
                .transaction()
                .map_err(|e| EngineError::Backend(e.to_string()))?;
            tx.execute("UPDATE inference_instances SET state = 'stopped', stopped_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), failure_code = NULL WHERE id = ?1", [&row.raw_id])
                .map_err(|error| EngineError::Backend(error.to_string()))?;
            crate::pool::release_stopped_instance(&tx, instance_id)
                .map_err(|error| EngineError::Backend(error.to_string()))?;
            tx.commit()
                .map_err(|e| EngineError::Backend(e.to_string()))?;
        }
        Ok(persisted.len())
    }

    pub(super) async fn recover_adopted_instance(
        &self,
        instance_id: Uuid,
        model_id: &str,
        profile_id: &str,
        container_id: Option<&str>,
        internal_port: i64,
        inventory: Option<&crate::models::ModelInventory>,
    ) -> Result<bool, EngineError> {
        let Some(inventory) = inventory else {
            return Ok(false);
        };
        let Some(recipe) = inventory.recipe(model_id).cloned() else {
            return Ok(false);
        };
        let Some(profile) = recipe
            .profiles
            .iter()
            .find(|profile| profile.id == profile_id)
            .cloned()
        else {
            return Ok(false);
        };
        let Some(workload_id) =
            container_id.filter(|id| spark_privd::adoption::valid_workload_id(id))
        else {
            return Ok(false);
        };
        let Ok(port) = u16::try_from(internal_port) else {
            return Ok(false);
        };
        let model = crate::store::model_row(&self.db.lock(), recipe.id())
            .map_err(|error| EngineError::Backend(error.to_string()))?;
        if !model.is_some_and(|model| {
            model.install_state == "installed"
                && model.recipe_revision == recipe.metadata.revision
                && model.source_revision == recipe.source.revision
        }) {
            return Ok(false);
        }
        let gpu_memory_utilisation_milli = declared_utilisation_milli(&profile);
        let instance = EngineInstance {
            instance_id,
            model_id: recipe.id().to_owned(),
            profile_id: profile.id.clone(),
            served_name: recipe.engine.served_name.clone(),
            model_snapshot: snapshot_path(self.models_root, &recipe),
            internal_port: port,
            api_key: String::new(),
            external_workload_id: Some(workload_id.to_owned()),
            recipe,
            profile,
            memory_baseline_bytes: self.telemetry.system().unified_memory_available_bytes,
            // Adopted container: we did not launch it, so we cannot set a cgroup cap.
            memory_limit_bytes: None,
            gpu_memory_utilisation_milli,
        };
        if !self.backend.health(&instance).await.unwrap_or(false)
            || self.backend.list_model_names(&instance).await.ok()
                != Some(vec![instance.served_name.clone()])
        {
            return Ok(false);
        }
        {
            let mut core = self.inner.lock();
            if core.instance.is_some() || core.transitioning {
                return Ok(false);
            }
            core.instance = Some(instance.clone());
            core.state = EngineState::Ready;
        }
        // Recheck liveness after publishing the instance because pre-lock health evidence can become stale.
        if !self.backend.is_running(&instance).await {
            let mut core = self.inner.lock();
            if core
                .instance
                .as_ref()
                .is_some_and(|current| current.instance_id == instance.instance_id)
            {
                core.instance = None;
                core.state = EngineState::Unloaded;
            }
            return Ok(false);
        }
        self.effects
            .guard_set_active(Some(crate::guard::ActiveProfile {
                model_id: instance.model_id,
                profile_id: instance.profile_id,
            }));
        Ok(true)
    }
}

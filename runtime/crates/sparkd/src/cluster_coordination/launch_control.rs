use super::*;

pub(super) struct LaunchControl<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) runtime: &'a dyn DistributedRuntimeControl,
    pub(super) validation: proof_validation::ProposalValidation<'a>,
}

impl LaunchControl<'_> {
    /// Gate advertised cluster inference on physical two-Spark qualification of the pinned image and topology.
    pub(super) fn start_local_launch(
        &self,
        cluster_id: Uuid,
        launch_id: Uuid,
        execution: &DistributedExecutionSpec,
    ) -> Result<(), CoordinationError> {
        execution.validate(launch_id)?;
        let execution_json = serde_json::to_string(execution)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let row: Option<(String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT t.proposal_json,t.state
                 FROM cluster_transactions t
                 JOIN cluster_state c ON c.id=t.cluster_id
                 WHERE t.cluster_id=?1 AND t.state='ready' AND c.state='ready'",
                [cluster_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((proposal_json, _)) = row else {
            return Err(CoordinationError::Conflict(
                "distributed launch requires a committed cluster".into(),
            ));
        };
        let proposal: ClusterProposal = serde_json::from_str(&proposal_json)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        self.validation.validate_local_software(&proposal)?;
        let existing: Option<(String, String, String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT recipe_id,profile_id,state,execution_spec_json
                 FROM cluster_launches WHERE launch_id=?1",
                [launch_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let needs_insert = match existing {
            Some((existing_recipe, existing_profile, state, existing_execution))
                if existing_recipe == execution.recipe_id
                    && existing_profile == execution.profile_id
                    && existing_execution == execution_json =>
            {
                if state == "running" {
                    return Ok(());
                }
                if state != "preparing" {
                    return Err(CoordinationError::Conflict(format!(
                        "launch cannot resume from {state}"
                    )));
                }
                false
            }
            Some(_) => {
                return Err(CoordinationError::Conflict(
                    "launch id was already used for different immutable inputs".into(),
                ));
            }
            None => true,
        };
        let worker_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != proposal.coordinator_node_id)
            .map(|member| member.node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("worker is absent".into()))?;
        let now = crate::store::now_iso8601();
        if needs_insert {
            let result = self.database.lock().execute(
                "INSERT INTO cluster_launches
                 (launch_id,cluster_id,recipe_id,profile_id,execution_spec_json,state,
                  coordinator_node_id,worker_node_id,created_at,updated_at)
                 VALUES(?1,?2,?3,?4,?5,'preparing',?6,?7,?8,?8)",
                rusqlite::params![
                    launch_id.to_string(),
                    cluster_id.to_string(),
                    execution.recipe_id,
                    execution.profile_id,
                    execution_json,
                    proposal.coordinator_node_id.to_string(),
                    worker_node_id.to_string(),
                    now,
                ],
            );
            if let Err(error) = result {
                // Interpret only uniqueness violations as existing launches; propagate disk and I/O failures.
                let already_launched = matches!(
                    &error,
                    rusqlite::Error::SqliteFailure(inner, _)
                        if inner.code == rusqlite::ErrorCode::ConstraintViolation
                );
                if already_launched {
                    return Err(CoordinationError::Conflict(
                        "this cluster already has an active distributed launch".into(),
                    ));
                }
                return Err(error.into());
            }
        }
        if let Err(error) =
            self.runtime
                .start(&proposal, self.identity.node_id(), launch_id, execution)
        {
            let rollback = self.runtime.stop(cluster_id, launch_id);
            return match rollback {
                Ok(()) => {
                    self.database.lock().execute(
                        "UPDATE cluster_launches SET state='failed',failure_code='START_FAILED',updated_at=?1
                         WHERE launch_id=?2 AND state='preparing'",
                        rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
                    )?;
                    Err(error)
                }
                Err(rollback_error) => {
                    self.database.lock().execute(
                        "UPDATE cluster_launches SET state='stopping',failure_code='START_ROLLBACK_UNPROVEN',updated_at=?1
                         WHERE launch_id=?2 AND state='preparing'",
                        rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
                    )?;
                    Err(CoordinationError::Runtime(format!(
                        "launch failed ({error}); cleanup could not be confirmed ({rollback_error})"
                    )))
                }
            };
        }
        let health = self
            .runtime
            .healthy(&proposal, self.identity.node_id(), launch_id);
        if health.as_ref().is_ok_and(|value| *value) {
            let changed = self.database.lock().execute(
                "UPDATE cluster_launches SET state='running',failure_code=NULL,updated_at=?1
                 WHERE launch_id=?2 AND state='preparing'",
                rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
            )?;
            if changed != 1 {
                self.runtime.stop(cluster_id, launch_id)?;
                return Err(CoordinationError::Conflict(
                    "distributed launch lost its transaction fence".into(),
                ));
            }
        } else {
            let failure_code = if health.is_err() {
                "HEALTH_PROBE_RETRY"
            } else {
                "WAITING_FOR_PEER_HEALTH"
            };
            self.database.lock().execute(
                "UPDATE cluster_launches SET failure_code=?1,updated_at=?2
                 WHERE launch_id=?3 AND state='preparing'",
                rusqlite::params![
                    failure_code,
                    crate::store::now_iso8601(),
                    launch_id.to_string()
                ],
            )?;
        }
        Ok(())
    }

    /// Retry idempotent launch steps until both exact Ray identities and the coordinator engine are verified.
    pub(super) fn reconcile_preparing_launches_once(&self) -> Result<usize, CoordinationError> {
        let rows = {
            let connection = self.database.lock();
            let mut statement = connection.prepare(
                "SELECT launch_id,cluster_id,execution_spec_json
                 FROM cluster_launches WHERE state='preparing' ORDER BY created_at ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut completed = 0;
        for (launch_id, cluster_id, execution_json) in rows {
            let launch_id = Uuid::parse_str(&launch_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let cluster_id = Uuid::parse_str(&cluster_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let execution: DistributedExecutionSpec = serde_json::from_str(&execution_json)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            self.start_local_launch(cluster_id, launch_id, &execution)?;
            if self.launch_status(launch_id)?.state == "running" {
                completed += 1;
            }
        }
        Ok(completed)
    }

    pub(super) fn launch_status(
        &self,
        launch_id: Uuid,
    ) -> Result<ClusterLaunchStatus, CoordinationError> {
        self.database
            .lock()
            .query_row(
                "SELECT launch_id,cluster_id,recipe_id,profile_id,state,
                        coordinator_node_id,worker_node_id,failure_code,updated_at
                 FROM cluster_launches WHERE launch_id=?1",
                [launch_id.to_string()],
                launch_status_from_row,
            )
            .optional()?
            .ok_or_else(|| CoordinationError::Conflict("cluster launch does not exist".into()))
    }

    pub(super) fn launches(&self) -> Result<Vec<ClusterLaunchStatus>, CoordinationError> {
        let connection = self.database.lock();
        let mut statement = connection.prepare(
            "SELECT launch_id,cluster_id,recipe_id,profile_id,state,
                    coordinator_node_id,worker_node_id,failure_code,updated_at
             FROM cluster_launches ORDER BY updated_at DESC, launch_id ASC",
        )?;
        Ok(statement
            .query_map([], launch_status_from_row)?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub(super) fn stop_local_launch(
        &self,
        launch_id: Uuid,
    ) -> Result<ClusterLaunchStatus, CoordinationError> {
        let status = self.launch_status(launch_id)?;
        if status.state == "stopped" {
            return Ok(status);
        }
        self.database.lock().execute(
            "UPDATE cluster_launches SET state='stopping',failure_code=NULL,updated_at=?1
             WHERE launch_id=?2 AND state!='stopped'",
            rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
        )?;
        if let Err(error) = self.runtime.stop(status.cluster_id, launch_id) {
            self.database.lock().execute(
                "UPDATE cluster_launches SET state='stopping',failure_code='STOP_UNPROVEN',updated_at=?1 WHERE launch_id=?2",
                rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
            )?;
            return Err(error);
        }
        self.database.lock().execute(
            "UPDATE cluster_launches SET state='stopped',failure_code='OWNER_STOPPED',updated_at=?1 WHERE launch_id=?2",
            rusqlite::params![crate::store::now_iso8601(), launch_id.to_string()],
        )?;
        self.launch_status(launch_id)
    }

    pub(super) fn stop_cluster_launches(
        &self,
        cluster_id: Uuid,
        stop_failure_code: &str,
        stopped_reason: &str,
        cluster_failure_state: &str,
    ) -> Result<(), CoordinationError> {
        let launches = {
            let conn = self.database.lock();
            let mut statement = conn.prepare(
                "SELECT launch_id FROM cluster_launches
                 WHERE cluster_id=?1 AND state != 'stopped'",
            )?;
            statement
                .query_map([cluster_id.to_string()], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        for launch in &launches {
            let launch_id = Uuid::parse_str(launch)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            self.database.lock().execute(
                "UPDATE cluster_launches SET state='stopping',failure_code=?1,updated_at=?2
                 WHERE launch_id=?3 AND state!='stopped'",
                rusqlite::params![stop_failure_code, crate::store::now_iso8601(), launch],
            )?;
            if let Err(error) = self.runtime.stop(cluster_id, launch_id) {
                self.database.lock().execute(
                    "UPDATE cluster_state SET state=?1,updated_at=?2 WHERE id=?3",
                    rusqlite::params![
                        cluster_failure_state,
                        crate::store::now_iso8601(),
                        cluster_id.to_string()
                    ],
                )?;
                return Err(error);
            }
            self.database.lock().execute(
                "UPDATE cluster_launches SET state='stopped',failure_code=?1,updated_at=?2
                 WHERE launch_id=?3 AND state='stopping'",
                rusqlite::params![stopped_reason, crate::store::now_iso8601(), launch],
            )?;
        }
        Ok(())
    }

    pub(super) fn reconcile_stopping_launches_once(&self) -> Result<usize, CoordinationError> {
        let launches = {
            let connection = self.database.lock();
            let mut statement = connection.prepare(
                "SELECT launch_id,cluster_id,failure_code
                 FROM cluster_launches WHERE state='stopping' ORDER BY created_at ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut completed = 0;
        for (launch_id, cluster_id, failure_code) in launches {
            let launch_uuid = Uuid::parse_str(&launch_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let cluster_uuid = Uuid::parse_str(&cluster_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            if let Err(error) = self.runtime.stop(cluster_uuid, launch_uuid) {
                tracing::warn!(%cluster_uuid, %launch_uuid, %error, "distributed launch cleanup remains unproven");
                continue;
            }
            let stopped_reason = match failure_code.as_deref() {
                Some("START_ROLLBACK_UNPROVEN") => "START_FAILED_CLEANED",
                Some("WORKER_LOSS_STOP_UNPROVEN") => "WORKER_LOST",
                Some("COORDINATOR_LOSS_STOP_UNPROVEN") => "COORDINATOR_LOST_PROMOTION_REQUIRED",
                Some("LOCAL_RUNTIME_STOP_UNPROVEN") => "LOCAL_RUNTIME_UNHEALTHY",
                Some("ROLLBACK_STOP_UNPROVEN") => "CLUSTER_ROLLED_BACK",
                _ => "OWNER_STOPPED",
            };
            completed += self.database.lock().execute(
                "UPDATE cluster_launches SET state='stopped',failure_code=?1,updated_at=?2
                 WHERE launch_id=?3 AND state='stopping'",
                rusqlite::params![stopped_reason, crate::store::now_iso8601(), launch_id],
            )?;
        }
        Ok(completed)
    }
}

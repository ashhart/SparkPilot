use super::*;

pub(super) struct ClusterHealthMonitor<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) link: &'a dyn ClusterLinkControl,
    pub(super) runtime: &'a dyn DistributedRuntimeControl,
    pub(super) publisher: event_publisher::CoordinationEvents<'a>,
    pub(super) launch_control: launch_control::LaunchControl<'a>,
    pub(super) failure_signal: failure_signal::LaunchFailureSignal<'a>,
    pub(super) monitor_failures: &'a Mutex<HashMap<Uuid, u8>>,
}

impl ClusterHealthMonitor<'_> {
    /// Stop distributed work without erasing the signed membership record.
    pub(super) fn handle_peer_loss(
        &self,
        cluster_id: Uuid,
        peer_node_id: Uuid,
    ) -> Result<ClusterPeerLoss, CoordinationError> {
        let proposal_json: String = self.database.lock().query_row(
            "SELECT proposal_json FROM cluster_transactions WHERE cluster_id=?1 AND state='ready'",
            [cluster_id.to_string()],
            |row| row.get(0),
        )?;
        let proposal: ClusterProposal = serde_json::from_str(&proposal_json)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        if peer_node_id == self.identity.node_id()
            || !proposal
                .members
                .iter()
                .any(|member| member.node_id == peer_node_id)
        {
            return Err(CoordinationError::Conflict(
                "the lost peer is not the other committed cluster member".into(),
            ));
        }
        let loss = if peer_node_id == proposal.coordinator_node_id {
            ClusterPeerLoss::Coordinator
        } else {
            ClusterPeerLoss::Worker
        };
        let health = loss.event_reason();
        let now = crate::store::now_iso8601();
        let mut conn = self.database.lock();
        let tx = conn.transaction()?;
        let member_changed = tx.execute(
            "UPDATE cluster_members
             SET reachable=0,qsfp_health=?1
             WHERE cluster_id=?2 AND node_id=?3
               AND (reachable!=0 OR COALESCE(qsfp_health,'')!=?1)",
            rusqlite::params![health, cluster_id.to_string(), peer_node_id.to_string()],
        )?;
        let cluster_changed = tx.execute(
            "UPDATE cluster_state SET state='degraded',updated_at=?1
             WHERE id=?2 AND state!='degraded'",
            rusqlite::params![now, cluster_id.to_string()],
        )?;
        tx.commit()?;
        drop(conn);
        if member_changed != 0 || cluster_changed != 0 {
            self.publisher.emit_cluster_event(
                cluster_id,
                "cluster.degraded",
                "error",
                serde_json::json!({
                    "reason": loss.event_reason(),
                    "peer_node_id": peer_node_id,
                    "distributed_stop": "required",
                    "promotion_required": loss == ClusterPeerLoss::Coordinator,
                }),
            );
        }
        self.failure_signal
            .signal_launch_failure(cluster_id, loss)?;
        self.launch_control.stop_cluster_launches(
            cluster_id,
            loss.stop_failure_code(),
            loss.stopped_reason(),
            "degraded",
        )?;
        Ok(loss)
    }

    /// After three consecutive peer-path failures, stop distributed work before standalone recovery; report transient misses without teardown.
    pub(super) fn monitor_committed_link_once(
        &self,
    ) -> Result<ClusterMonitorOutcome, CoordinationError> {
        let row: Option<(String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT cluster_id,proposal_json FROM cluster_transactions WHERE state='ready'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((cluster_id, proposal_json)) = row else {
            return Ok(ClusterMonitorOutcome::Idle);
        };
        let cluster_id = Uuid::parse_str(&cluster_id)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let proposal: ClusterProposal = serde_json::from_str(&proposal_json)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let peer_node_id = proposal
            .members
            .iter()
            .find(|member| member.node_id != self.identity.node_id())
            .map(|member| member.node_id)
            .ok_or_else(|| CoordinationError::InvalidProposal("peer is absent".into()))?;
        let launches = {
            let conn = self.database.lock();
            let mut statement = conn.prepare(
                "SELECT launch_id FROM cluster_launches WHERE cluster_id=?1 AND state='running'",
            )?;
            statement
                .query_map([cluster_id.to_string()], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let runtime_health = launches.iter().try_for_each(|launch| {
            let launch_id = Uuid::parse_str(launch)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            match self
                .runtime
                .healthy(&proposal, self.identity.node_id(), launch_id)?
            {
                true => Ok(()),
                false => Err(CoordinationError::Runtime(format!(
                    "distributed launch {launch_id} cannot prove two live members"
                ))),
            }
        });
        if let Err(error) = runtime_health {
            let failures = {
                let mut monitor = self.monitor_failures.lock();
                let failures = monitor.entry(cluster_id).or_insert(0);
                *failures = failures.saturating_add(1);
                *failures
            };
            let changed = self.database.lock().execute(
                "UPDATE cluster_state SET state='degraded',updated_at=?1
                 WHERE id=?2 AND state='ready'",
                rusqlite::params![crate::store::now_iso8601(), cluster_id.to_string()],
            )?;
            if changed != 0 {
                self.publisher.emit_cluster_event(
                    cluster_id,
                    "cluster.degraded",
                    "warning",
                    serde_json::json!({
                        "reason": "local_runtime_health_probe_failed",
                        "local_node_id": self.identity.node_id(),
                        "consecutive_failures": failures,
                    }),
                );
            }
            if failures < 3 {
                tracing::warn!(%cluster_id, %error, "local distributed runtime health probe failed");
                return Ok(ClusterMonitorOutcome::Degraded {
                    consecutive_failures: failures,
                });
            }
            self.launch_control.stop_cluster_launches(
                cluster_id,
                "LOCAL_RUNTIME_STOP_UNPROVEN",
                "LOCAL_RUNTIME_UNHEALTHY",
                "degraded",
            )?;
            self.publisher.emit_cluster_event(
                cluster_id,
                "cluster.degraded",
                "error",
                serde_json::json!({
                    "reason": "local_runtime_unhealthy",
                    "local_node_id": self.identity.node_id(),
                    "distributed_stop": "proved",
                }),
            );
            return Ok(ClusterMonitorOutcome::LocalRuntimeStopped);
        }
        let current_health = self
            .link
            .prove(&proposal, self.identity.node_id())
            .map(|_| ());
        match current_health {
            Ok(_) => {
                self.monitor_failures.lock().remove(&cluster_id);
                let now = crate::store::now_iso8601();
                let mut connection = self.database.lock();
                let transaction = connection.transaction()?;
                let peer_changed = transaction.execute(
                    "UPDATE cluster_members
                     SET reachable=1,qsfp_health='healthy',last_seen_at=?1
                     WHERE cluster_id=?2 AND node_id=?3
                       AND (reachable!=1 OR COALESCE(qsfp_health,'')!='healthy')",
                    rusqlite::params![now, cluster_id.to_string(), peer_node_id.to_string(),],
                )?;
                if peer_changed == 0 {
                    transaction.execute(
                        "UPDATE cluster_members SET last_seen_at=?1
                         WHERE cluster_id=?2 AND node_id=?3",
                        rusqlite::params![now, cluster_id.to_string(), peer_node_id.to_string(),],
                    )?;
                }
                let cluster_changed = transaction.execute(
                    "UPDATE cluster_state SET state='ready',updated_at=?1
                     WHERE id=?2 AND state='degraded'",
                    rusqlite::params![now, cluster_id.to_string()],
                )?;
                transaction.commit()?;
                drop(connection);
                if peer_changed != 0 {
                    self.publisher.emit_cluster_event(
                        cluster_id,
                        "cluster.link.changed",
                        "notice",
                        serde_json::json!({
                            "peer_node_id": peer_node_id,
                            "link_up": true,
                        }),
                    );
                }
                if cluster_changed != 0 {
                    self.publisher.emit_cluster_event(
                        cluster_id,
                        "cluster.ready",
                        "notice",
                        serde_json::json!({
                            "reason": "peer_recovered",
                            "peer_node_id": peer_node_id,
                        }),
                    );
                }
                Ok(ClusterMonitorOutcome::Healthy)
            }
            Err(error) => {
                let failures = {
                    let mut monitor = self.monitor_failures.lock();
                    let failures = monitor.entry(cluster_id).or_insert(0);
                    *failures = failures.saturating_add(1);
                    *failures
                };
                if failures < 3 {
                    let now = crate::store::now_iso8601();
                    let mut connection = self.database.lock();
                    let transaction = connection.transaction()?;
                    let peer_changed = transaction.execute(
                        "UPDATE cluster_members
                         SET reachable=0,qsfp_health='unreachable'
                         WHERE cluster_id=?1 AND node_id=?2
                           AND (reachable!=0 OR COALESCE(qsfp_health,'')!='unreachable')",
                        rusqlite::params![cluster_id.to_string(), peer_node_id.to_string()],
                    )?;
                    let cluster_changed = transaction.execute(
                        "UPDATE cluster_state SET state='degraded',updated_at=?1
                         WHERE id=?2 AND state='ready'",
                        rusqlite::params![now, cluster_id.to_string()],
                    )?;
                    transaction.commit()?;
                    drop(connection);
                    if peer_changed != 0 {
                        self.publisher.emit_cluster_event(
                            cluster_id,
                            "cluster.link.changed",
                            "warning",
                            serde_json::json!({
                                "peer_node_id": peer_node_id,
                                "link_up": false,
                            }),
                        );
                    }
                    if cluster_changed != 0 {
                        self.publisher.emit_cluster_event(
                            cluster_id,
                            "cluster.degraded",
                            "warning",
                            serde_json::json!({
                                "reason": "peer_health_probe_failed",
                                "peer_node_id": peer_node_id,
                                "consecutive_failures": failures,
                            }),
                        );
                    }
                    return Ok(ClusterMonitorOutcome::Degraded {
                        consecutive_failures: failures,
                    });
                }
                let peer = self.handle_peer_loss(cluster_id, peer_node_id)?;
                tracing::warn!(%cluster_id, %peer_node_id, %error, "cluster peer was lost; local distributed work stopped");
                Ok(ClusterMonitorOutcome::DistributedWorkStopped { peer })
            }
        }
    }
}

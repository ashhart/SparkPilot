use super::*;

pub(super) struct LaunchFailureSignal<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) launch_failures:
        &'a Mutex<HashMap<Uuid, tokio::sync::watch::Sender<Option<ClusterPeerLoss>>>>,
}

impl LaunchFailureSignal<'_> {
    pub(super) fn signal_launch_failure(
        &self,
        cluster_id: Uuid,
        loss: ClusterPeerLoss,
    ) -> Result<(), CoordinationError> {
        let launch_ids = {
            let connection = self.database.lock();
            let mut statement = connection.prepare(
                "SELECT launch_id FROM cluster_launches
                 WHERE cluster_id=?1 AND state IN ('preparing','running','degraded','stopping')",
            )?;
            statement
                .query_map([cluster_id.to_string()], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut senders = self.launch_failures.lock();
        for launch_id in launch_ids {
            let launch_id = Uuid::parse_str(&launch_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            senders
                .entry(launch_id)
                .or_insert_with(|| tokio::sync::watch::channel(None).0)
                .send_replace(Some(loss));
        }
        Ok(())
    }
}

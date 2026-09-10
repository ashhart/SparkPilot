// Reconcile cluster launches, expired transactions and peer health on the daemon's own timer.

use std::sync::Arc;

use sparkd::cluster_coordination::ClusterCoordinationService;

pub(super) fn spawn(coordination: Arc<ClusterCoordinationService>) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(tokio::time::Duration::from_secs(10));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            let coordinator = coordination.clone();
            match tokio::task::spawn_blocking(move || {
                coordinator.reconcile_stopping_launches_once()?;
                coordinator.reconcile_expired_transactions_once(time::OffsetDateTime::now_utc())?;
                coordinator.reconcile_preparing_launches_once()?;
                coordinator.monitor_committed_link_once()
            })
            .await
            {
                Ok(Ok(sparkd::cluster_coordination::ClusterMonitorOutcome::Degraded {
                    consecutive_failures,
                })) => tracing::warn!(consecutive_failures, "cluster peer health probe failed"),
                Ok(Ok(
                    sparkd::cluster_coordination::ClusterMonitorOutcome::DistributedWorkStopped {
                        peer,
                    },
                )) => tracing::error!(?peer, "cluster peer was lost; distributed work is stopped"),
                Ok(Err(error)) => tracing::error!(%error, "cluster peer recovery failed"),
                Err(error) => tracing::error!(%error, "cluster peer monitor stopped unexpectedly"),
                _ => {}
            }
        }
    });
}

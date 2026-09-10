use super::*;

/// Keep retention and expired-worker recovery active between daemon restarts.
pub(super) fn spawn_housekeeping(state: AppState) {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            let state = state.clone();
            let outcome =
                tokio::task::spawn_blocking(move || -> Result<(), sparkd::store::StoreError> {
                    if let Some(database) = &state.database {
                        let mut conn = database.lock();
                        sparkd::store::prune_expired_records(&conn, &state.clock.now_rfc3339())?;
                        sparkd::store::prune_events(
                            &conn,
                            &state.event_retention,
                            &state.clock.now_rfc3339(),
                        )?;
                        sparkd::store::prune_usage_daily(
                            &conn,
                            &state.clock.now_rfc3339(),
                            state.usage_retention_days,
                        )?;
                        state.jobs.reap_expired_leases(&mut conn)?;
                    }
                    Ok(())
                })
                .await;
            if !matches!(outcome, Ok(Ok(()))) {
                tracing::warn!(?outcome, "runtime housekeeping failed; retrying");
            }
        }
    });
}

/// Report `READY=1` after the listener binds, then feed `WatchdogSec=`.
pub(super) fn spawn_systemd_readiness(handle: axum_server::Handle<SocketAddr>) {
    tokio::spawn(async move {
        if handle.listening().await.is_none() {
            return;
        }
        if let Err(error) = spark_core::notify::ready() {
            tracing::warn!(%error, "failed to report readiness to systemd");
        }
        let Some(interval) = spark_core::notify::watchdog_interval() else {
            return;
        };
        let mut ticker = tokio::time::interval(interval);
        ticker.tick().await;
        loop {
            ticker.tick().await;
            if let Err(error) = spark_core::notify::watchdog_ping() {
                tracing::warn!(%error, "watchdog ping failed");
                return;
            }
        }
    });
}

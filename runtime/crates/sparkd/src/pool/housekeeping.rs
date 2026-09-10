use super::*;

/// Recover before listening and expire undispatched leases independently of traffic; report pool preparation faults without taking management offline.
pub fn spawn_housekeeping(state: AppState) -> Result<tokio::task::JoinHandle<()>, PoolError> {
    let initial_error = state.pools.prepare(&state).err();
    if let Some(error) = &initial_error {
        tracing::warn!(%error, "pool admission unavailable; management remains available");
    }
    Ok(tokio::spawn(async move {
        let mut failed = initial_error.is_some();
        let mut ticks = tokio::time::interval(Duration::from_secs(1));
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            ticks.tick().await;
            let current = state.clone();
            match tokio::task::spawn_blocking(move || current.pools.prepare(&current)).await {
                Ok(Ok(())) => {
                    if failed {
                        tracing::info!("pool maintenance recovered; admission can resume");
                    }
                    failed = false;
                }
                result => {
                    if !failed {
                        tracing::warn!(
                            ?result,
                            "pool lease maintenance failed; admission remains fail closed"
                        );
                    }
                    failed = true;
                }
            }
        }
    }))
}

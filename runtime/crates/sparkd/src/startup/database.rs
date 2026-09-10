use super::*;

pub(super) fn open(
    data_dir: &std::path::Path,
    retention: &sparkd::events::EventRetention,
) -> Result<rusqlite::Connection, Box<dyn std::error::Error>> {
    let db_path = data_dir.join("runtime.db");
    let mut conn = migration::open(&db_path)?;
    let migrations = migration::migrate_with_recovery_point(&mut conn, &db_path)?;
    if let Some(recovery_point) = &migrations.recovery_point {
        tracing::info!(path = %recovery_point.display(), "recovery point written");
    }
    if !migrations.applied.is_empty() {
        tracing::info!(versions = ?migrations.applied, "database migrations applied");
    }

    // Verify audit integrity at startup and report breaks prominently without disabling appliance management.
    match sparkd::audit::verify_chain(&conn) {
        Ok(None) => tracing::info!("audit chain verified intact at startup"),
        Ok(Some(sequence)) => tracing::error!(
            sequence,
            "AUDIT CHAIN INTEGRITY CHECK FAILED at this sequence: the audit log              has been altered or truncated; tamper-evidence from here on is void"
        ),
        Err(error) => {
            tracing::error!(%error, "audit chain could not be verified at startup")
        }
    }

    // Prune durable events to the replay-preserving retention window at startup and during housekeeping.
    let now = sparkd::clock::system_clock().now_rfc3339();
    match sparkd::store::prune_events(&conn, retention, &now) {
        Ok(0) => {}
        Ok(removed) => {
            tracing::info!(
                removed,
                "trimmed the durable event log to the retention window"
            )
        }
        Err(error) => {
            tracing::warn!(%error, "could not trim the durable event log at startup")
        }
    }

    Ok(conn)
}

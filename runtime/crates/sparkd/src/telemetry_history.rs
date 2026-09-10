//! Sample local telemetry independently of open clients, using existing local probes without generating endpoint traffic.

use std::time::Duration;

use spark_telemetry::{
    DEFAULT_AGGREGATE_RETENTION_SECONDS, DEFAULT_RAW_RETENTION_SECONDS, RAW_BUCKET_SECONDS,
    SystemMonitor, TelemetrySample,
};

use crate::guard::MemoryGuardService;
use crate::state::AppState;

/// Start only with a database and reread consent every tick so withdrawal stops recording without restart.
pub fn spawn(state: AppState) {
    let Some(database) = state.database.clone() else {
        return;
    };
    let consent = state.telemetry_consent.clone();
    let clock = state.clock.clone();

    tokio::spawn(async move {
        let mut sampling = tokio::time::interval(Duration::from_secs(RAW_BUCKET_SECONDS as u64));
        sampling.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut purged = false;
        loop {
            sampling.tick().await;
            let now = clock.now().unix_timestamp();
            if !consent.read().functional {
                // Retry purge until confirmed so transient storage failure cannot retain withdrawn telemetry indefinitely.
                if !purged {
                    purged = purge_once(&database).await;
                }
                continue;
            }
            purged = false;
            let sample_state = state.clone();
            // Move blocking probes and writes off the reactor and prune expired raw rows in the same sampling pass.
            let outcome =
                tokio::task::spawn_blocking(move || sample_once(&sample_state, now)).await;
            match outcome {
                Ok(Err(error)) => {
                    tracing::warn!(%error, "telemetry sample or compaction failed")
                }
                Err(error) => tracing::warn!(%error, "telemetry sampler worker failed"),
                Ok(Ok(_)) => {}
            }
        }
    });
}

fn sample_once(state: &AppState, now: i64) -> rusqlite::Result<()> {
    let sample = collect(&*state.telemetry, state.guard.as_deref());
    let database = state
        .database
        .as_ref()
        .ok_or(rusqlite::Error::InvalidQuery)?;
    let mut conn = database.lock();
    let consent = state.telemetry_consent.read();
    if !consent.functional {
        return Ok(());
    }
    spark_telemetry::record_sample(&conn, now, &sample)?;
    crate::request_history::prune(&conn, now)?;
    spark_telemetry::compact(
        &mut conn,
        now,
        DEFAULT_RAW_RETENTION_SECONDS,
        DEFAULT_AGGREGATE_RETENTION_SECONDS,
    )?;
    Ok(())
}

/// One purge attempt. `true` only when the rows are confirmed gone.
async fn purge_once(database: &std::sync::Arc<parking_lot::Mutex<rusqlite::Connection>>) -> bool {
    let database = database.clone();
    match tokio::task::spawn_blocking(move || {
        let conn = database.lock();
        spark_telemetry::purge(&conn)?;
        crate::request_history::purge(&conn)
    })
    .await
    {
        Ok(Ok(())) => true,
        Ok(Err(error)) => {
            tracing::warn!(%error, "telemetry history purge failed; retrying");
            false
        }
        Err(error) => {
            tracing::warn!(%error, "telemetry history purge worker failed; retrying");
            false
        }
    }
}

/// One sanitized reading from probes the daemon already runs.
pub fn collect(monitor: &dyn SystemMonitor, guard: Option<&MemoryGuardService>) -> TelemetrySample {
    let system = monitor.system();
    let hardware = monitor.hardware();
    let inference = monitor.inference();
    let pressure = guard.map_or_else(
        || system.memory_pressure.api_name(),
        |guard| guard.reading().state.api_name(),
    );
    TelemetrySample {
        cpu_utilisation: Some(system.cpu_utilisation),
        load_average_1m: Some(system.load_average_1m),
        memory_total_bytes: i64::try_from(system.unified_memory_total_bytes).ok(),
        memory_available_bytes: i64::try_from(system.unified_memory_available_bytes).ok(),
        memory_pressure: Some(pressure.to_owned()),
        temperature_celsius: system
            .temperature_celsius
            .or(hardware.accelerator.temperature_celsius),
        accelerator_utilisation: hardware.accelerator.utilisation,
        accelerator_memory_used_bytes: hardware
            .accelerator
            .memory_used_bytes
            .and_then(|value| i64::try_from(value).ok()),
        accelerator_memory_total_bytes: hardware
            .accelerator
            .memory_total_bytes
            .and_then(|value| i64::try_from(value).ok()),
        active_requests: Some(i64::from(inference.active_requests)),
        queue_depth: inference.queue_depth.map(i64::from),
        tokens_per_second: inference.tokens_per_second,
        time_to_first_token_ms: inference.time_to_first_token_ms,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use parking_lot::Mutex;
    use rusqlite::Connection;

    use super::*;

    #[test]
    fn pending_sampler_does_not_record_after_consent_is_withdrawn() {
        use crate::appliance_api::TelemetryConsentConfig;
        use spark_core::identity::{FileIdentityStore, IdentityStore};
        use spark_telemetry::{FakeSystemMonitor, InferenceSnapshot, SystemSnapshot};

        struct WithdrawOnProbe(Arc<parking_lot::RwLock<TelemetryConsentConfig>>);
        impl SystemMonitor for WithdrawOnProbe {
            fn system(&self) -> SystemSnapshot {
                self.0.write().functional = false;
                FakeSystemMonitor.system()
            }
            fn inference(&self) -> InferenceSnapshot {
                FakeSystemMonitor.inference()
            }
        }
        let directory = tempfile::tempdir().unwrap();
        let identity = FileIdentityStore::new(directory.path().join("identity"))
            .load_or_create("consent-test")
            .unwrap();
        let consent = Arc::new(parking_lot::RwLock::new(TelemetryConsentConfig {
            functional: true,
            technical: false,
        }));
        let db = database();
        let mut state = AppState::new(
            crate::state::RuntimeConfig {
                api_major: 1,
                runtime_version: "test".into(),
                listen: "127.0.0.1:0".parse().unwrap(),
                node_name: "consent-test".into(),
                data_dir: directory.path().into(),
                advertise: false,
                tls: false,
            },
            identity,
            Arc::new(WithdrawOnProbe(consent.clone())),
            None,
        );
        state.database = Some(db.clone());
        state.telemetry_consent = consent;
        sample_once(&state, 1_800_000_000).unwrap();
        assert!(!state.telemetry_consent.read().functional);
        assert_eq!(
            rows(&db),
            0,
            "a pending probe recorded after consent withdrawal"
        );
    }

    const SCHEMA: &str = include_str!("../migrations/0017_telemetry_history.sql");

    fn database() -> Arc<Mutex<Connection>> {
        let conn = Connection::open_in_memory().expect("open");
        conn.execute_batch(SCHEMA).expect("schema");
        conn.execute_batch(include_str!("../migrations/0024_inference_requests.sql"))
            .expect("request schema");
        Arc::new(Mutex::new(conn))
    }

    fn rows(database: &Arc<Mutex<Connection>>) -> i64 {
        database
            .lock()
            .query_row("SELECT COUNT(*) FROM telemetry_samples", [], |row| {
                row.get(0)
            })
            .unwrap()
    }

    /// A failed consent-withdrawal purge must keep retrying until deletion succeeds.
    #[tokio::test]
    async fn a_purge_that_fails_is_retried_until_it_succeeds() {
        let database = database();
        spark_telemetry::record_sample(
            &database.lock(),
            1_000_000_020,
            &spark_telemetry::TelemetrySample::default(),
        )
        .unwrap();

        // Use a rejecting trigger to exercise storage failure during purge.
        database
            .lock()
            .execute_batch(
                "CREATE TRIGGER refuse_purge BEFORE DELETE ON telemetry_samples
                 BEGIN SELECT RAISE(ABORT, 'purge refused'); END;",
            )
            .unwrap();
        assert!(
            !purge_once(&database).await,
            "a refused purge reported success"
        );
        assert_eq!(rows(&database), 1, "the row went despite the refusal");

        // Repeated purge failures must remain failures so the caller never marks incomplete deletion done.
        assert!(!purge_once(&database).await);

        database
            .lock()
            .execute_batch("DROP TRIGGER refuse_purge")
            .unwrap();
        assert!(
            purge_once(&database).await,
            "the recovered purge was not confirmed"
        );
        assert_eq!(rows(&database), 0);
    }

    /// Prune at the exact retention cutoff during sampling, without retaining the remainder of its minute.
    #[test]
    fn no_raw_bucket_older_than_the_exact_cutoff_survives_a_sampling_pass() {
        let database = database();
        // Use a non-minute-aligned base to distinguish exact cutoff pruning from minute flooring.
        let base = 1_000_000_017;
        {
            let conn = database.lock();
            for step in 0..12 {
                spark_telemetry::record_sample(
                    &conn,
                    base + step * spark_telemetry::RAW_BUCKET_SECONDS,
                    &spark_telemetry::TelemetrySample::default(),
                )
                .unwrap();
            }
        }
        // One sampling tick past the oldest reading's expiry.
        let now = base + DEFAULT_RAW_RETENTION_SECONDS + spark_telemetry::RAW_BUCKET_SECONDS;
        {
            let mut conn = database.lock();
            spark_telemetry::record_sample(
                &conn,
                now,
                &spark_telemetry::TelemetrySample::default(),
            )
            .unwrap();
            spark_telemetry::compact(
                &mut conn,
                now,
                DEFAULT_RAW_RETENTION_SECONDS,
                DEFAULT_AGGREGATE_RETENTION_SECONDS,
            )
            .unwrap();
        }
        let cutoff = now - DEFAULT_RAW_RETENTION_SECONDS;
        let survivors: Vec<i64> = database
            .lock()
            .prepare("SELECT bucket_start FROM telemetry_samples ORDER BY bucket_start")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert!(!survivors.is_empty(), "the pass deleted everything");
        for bucket in survivors {
            assert!(
                bucket >= cutoff,
                "a raw bucket sat {}s past the {DEFAULT_RAW_RETENTION_SECONDS}s window",
                cutoff - bucket
            );
        }
    }

    #[test]
    fn a_collected_sample_carries_no_free_text() {
        let monitor = spark_telemetry::FakeSystemMonitor;
        let sample = collect(&monitor, None);
        // Permit only schema-approved pressure tokens and numeric sample fields.
        if let Some(pressure) = &sample.memory_pressure {
            assert!(
                ["normal", "warning", "critical", "emergency"].contains(&pressure.as_str()),
                "collect produced {pressure:?} as a memory pressure"
            );
        }
    }
}

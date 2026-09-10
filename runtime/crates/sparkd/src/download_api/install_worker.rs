use super::*;

/// Serialize install workers without holding the shared database lock.
pub(super) static DOWNLOAD_WORKER_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());

/// Bound waiting for the serialized install worker and report saturation before operations expire without explanation.
pub(super) const DOWNLOAD_WORKER_WAIT: std::time::Duration =
    std::time::Duration::from_secs(30 * 60);

pub(super) fn acquire_download_worker(
    lease: &crate::jobs::OperationLease,
) -> Option<parking_lot::MutexGuard<'static, ()>> {
    let deadline = std::time::Instant::now() + DOWNLOAD_WORKER_WAIT;
    loop {
        if lease.is_cancelled() {
            return None;
        }
        if let Some(guard) = DOWNLOAD_WORKER_LOCK.try_lock_for(std::time::Duration::from_millis(25))
        {
            return Some(guard);
        }
        if std::time::Instant::now() >= deadline {
            tracing::warn!(
                "gave up waiting for the download worker; another install has held it for {}s",
                DOWNLOAD_WORKER_WAIT.as_secs()
            );
            return None;
        }
    }
}

pub(crate) fn ensure_engine_image_ready(
    privileged: &crate::privd::PrivilegedClient,
    image_digest: &str,
) -> Result<(), &'static str> {
    let request_id = uuid::Uuid::new_v4();
    let response = privileged
        .call(PrivilegedOperation::EnsureEngineImage {
            request_id,
            image_digest: image_digest.to_owned(),
        })
        .map_err(|_| "privileged image preparation was unavailable")?;
    validate_engine_image_readiness(request_id, image_digest, &response)
}

/// Publish database and event progress while observing durable-job cancellation.
pub(super) struct RegistryCancel {
    pub(super) registry: std::sync::Arc<parking_lot::Mutex<crate::jobs::CancellationRegistry>>,
    pub(super) operation_id: uuid::Uuid,
}

impl IsCancelled for RegistryCancel {
    fn is_set(&self) -> bool {
        self.registry.lock().is_cancelled(&self.operation_id)
    }
}

pub(super) struct DbProgressSink<'a> {
    pub(super) database: Arc<parking_lot::Mutex<rusqlite::Connection>>,
    pub(super) events: EventBus,
    pub(super) node_id: String,
    pub(super) operation_id: uuid::Uuid,
    pub(super) model_id: String,
    /// Borrow the operation lease for progress; the worker retains ownership for terminal completion.
    pub(super) lease: &'a crate::jobs::OperationLease,
    /// Throttle repeated stage writes rather than mirroring every download chunk into the database.
    pub(super) last_written: parking_lot::Mutex<Option<(String, std::time::Instant)>>,
}

/// Limit stage-write amplification within the heartbeat and lease bounds; background heartbeats remain responsible for liveness.
pub(super) const STAGE_WRITE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(1);

impl ProgressSink for DbProgressSink<'_> {
    fn note(
        &self,
        relative_path: &str,
        _file_index: usize,
        _total: usize,
        bytes_done: u64,
        bytes_total: u64,
    ) -> Result<(), String> {
        // Release the file-progress database guard before stage writes acquire the same non-reentrant mutex.
        let conn = self.database.lock();
        crate::store::mark_model_download_progress(
            &conn,
            &self.model_id,
            relative_path,
            bytes_done,
            bytes_done < bytes_total,
        )
        .map_err(|error| error.to_string())?;
        let progress = if bytes_total == 0 {
            0.0
        } else {
            bytes_done as f64 / bytes_total as f64
        };
        self.events.emit(
            Some(&conn),
            &self.node_id,
            Some(self.operation_id),
            "model.download.progress",
            "info",
            json!({ "stage": "downloading", "progress": progress }),
        );
        Ok(())
    }

    fn stage(&self, stage: &str, progress: Option<f64>) {
        // Always persist stage transitions and completion so throttling cannot hide their ordering.
        let now = std::time::Instant::now();
        let finished = progress.is_some_and(|value| value >= 1.0);
        {
            let mut last = self.last_written.lock();
            let due = match last.as_ref() {
                Some((written, at)) => {
                    written != stage || finished || now.duration_since(*at) >= STAGE_WRITE_INTERVAL
                }
                None => true,
            };
            if !due {
                return;
            }
            *last = Some((stage.to_owned(), now));
        }

        // Ignore stage writes after lease loss without failing valid downloads; cancellation still arrives through the registry.
        let _ = self.lease.set_stage(stage, progress);
    }
}

/// Resume content-addressed idempotent install work only after callers persist its queued operation.
pub(crate) fn spawn_install_worker(
    state: &AppState,
    operation_id: uuid::Uuid,
    model_id: &str,
    provider_credential_id: Option<uuid::Uuid>,
) -> Result<(), String> {
    let db = state
        .database
        .as_ref()
        .ok_or_else(|| "no database".to_owned())?;
    let inventory = state
        .models
        .as_ref()
        .ok_or_else(|| "inventory unavailable".to_owned())?
        .snapshot();
    let recipe = inventory
        .recipe(model_id)
        .ok_or_else(|| "model recipe unavailable".to_owned())?
        .clone();
    let credential_path = match provider_credential_id {
        Some(credential_id) => {
            let store = CredentialStore::with_clock(&state.config.data_dir, state.clock.clone());
            let connection = db.lock();
            let provider = store
                .provider(&connection, credential_id)?
                .ok_or_else(|| "provider credential is unavailable".to_owned())?;
            if provider != recipe.source.provider {
                return Err("provider credential does not match the model source".to_owned());
            }
            Some(
                store
                    .resolve(&connection, credential_id)?
                    .ok_or_else(|| "provider credential is unavailable".to_owned())?,
            )
        }
        None if recipe.source.gated => {
            return Err("gated model requires a provider credential".to_owned());
        }
        None => None,
    };
    let coordinator = state
        .download
        .coordinator
        .as_ref()
        .ok_or_else(|| "download coordinator unavailable".to_owned())?
        .clone();
    let db_for_sink = db.clone();
    let events = state.events.clone();
    let node_id = state.identity.node_id().to_string();
    let model_id = recipe.id().to_owned();
    let models_root = state.storage.models.clone();
    let downloads_root = state.storage.downloads.clone();
    let registry = state.jobs.cancellation_registry();
    let disk_reserve_bytes =
        state
            .disk_reserve_bytes
            .saturating_add(if recipe.uses_qwen38_preparation() {
                30 * 1024 * 1024 * 1024
            } else {
                0
            });
    let privileged = state.privileged.clone();

    state
        .jobs
        .spawn_leased(db_for_sink.clone(), operation_id, move |lease| {
            let Some(_worker_guard) = acquire_download_worker(&lease) else {
                lease.settle_failed("OPERATION_CANCELLED");
                registry.lock().clear(&operation_id);
                return;
            };
            if let Some(privileged) = privileged.as_ref() {
                if lease.is_cancelled() {
                    lease.settle_failed("OPERATION_CANCELLED");
                    registry.lock().clear(&operation_id);
                    return;
                }
                if lease.set_stage("preparing_engine_image", None).is_err() {
                    registry.lock().clear(&operation_id);
                    return;
                }
                if lease.is_cancelled() {
                    lease.settle_failed("OPERATION_CANCELLED");
                    registry.lock().clear(&operation_id);
                    return;
                }
                if ensure_engine_image_ready(privileged, &recipe.engine.image).is_err() {
                    lease.settle_failed("MODEL_ENGINE_IMAGE_UNAVAILABLE");
                    registry.lock().clear(&operation_id);
                    return;
                }
                if lease.is_cancelled() {
                    lease.settle_failed("OPERATION_CANCELLED");
                    registry.lock().clear(&operation_id);
                    return;
                }
            }
            if let Err(error) = std::fs::create_dir_all(&downloads_root) {
                lease.settle_failed(&format!("download directory unavailable: {error}"));
                registry.lock().clear(&operation_id);
                return;
            }
            // Preflight the tighter free-space limit across staging and models filesystems, which may be separate bind mounts.
            let disk_free_bytes = crate::download_http::disk_free_bytes(&downloads_root)
                .min(crate::download_http::disk_free_bytes(&models_root));
            let ctx = DownloadContext {
                root: downloads_root,
                cancel: Arc::new(RegistryCancel {
                    registry: registry.clone(),
                    operation_id,
                }),
                disk_free_bytes,
                disk_reserve_bytes,
                fetches: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            };
            let sink = DbProgressSink {
                database: db_for_sink.clone(),
                events,
                node_id,
                operation_id,
                model_id,
                lease: &lease,
                last_written: parking_lot::Mutex::new(None),
            };
            let outcome = coordinator.install_with_credential(
                &db_for_sink,
                &recipe,
                &ctx,
                &sink,
                &models_root,
                credential_path.as_deref(),
            );
            // End the progress sink's borrow before moving the lease into terminal completion.
            drop(sink);
            match outcome {
                Ok(()) => {
                    lease.settle_succeeded(&json!({ "installed": true }));
                }
                Err(crate::download::DownloadError::Cancelled) => {
                    lease.settle_failed("OPERATION_CANCELLED");
                }
                Err(error) => {
                    lease.settle_failed(&format!("{error}"));
                }
            }
            registry.lock().clear(&operation_id);
        })
        .map_err(|error| error.to_string())?;
    Ok(())
}

use super::*;

#[derive(Debug, thiserror::Error)]
pub enum LeaseError {
    #[error("operation lease is held by another live worker")]
    Held,
    #[error("all {0} operation workers are busy")]
    Overloaded(usize),
    #[error("operation lease ownership was lost")]
    Lost,
    #[error(transparent)]
    Store(#[from] store::StoreError),
}

impl From<rusqlite::Error> for LeaseError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Store(store::StoreError::from(error))
    }
}

/// Lease ownership ends on a terminal transition; dropping its capability only stops renewal.
pub struct OperationLease {
    jobs: JobService,
    database: Arc<Mutex<Connection>>,
    operation_id: Uuid,
    owner: String,
    /// The value `acquire_lease` raised the operation's fence to; every write this lease makes carries it.
    fence: i64,
    lost: Arc<AtomicBool>,
    stop: Option<mpsc::Sender<()>>,
    heartbeat: Option<std::thread::JoinHandle<()>>,
    finished: bool,
}

impl OperationLease {
    pub(super) fn new(
        jobs: JobService,
        database: Arc<Mutex<Connection>>,
        id: Uuid,
        owner: String,
        fence: i64,
    ) -> Self {
        let lost = Arc::new(AtomicBool::new(false));
        let (stop_tx, stop_rx) = mpsc::channel();
        let heartbeat = spawn_heartbeat(
            jobs.clone(),
            database.clone(),
            id,
            owner.clone(),
            fence,
            lost.clone(),
            stop_rx,
        );
        Self {
            jobs,
            database,
            operation_id: id,
            owner,
            fence,
            lost,
            stop: Some(stop_tx),
            heartbeat: Some(heartbeat),
            finished: false,
        }
    }

    pub fn operation_id(&self) -> Uuid {
        self.operation_id
    }

    pub fn owner(&self) -> &str {
        &self.owner
    }

    /// The fence this lease holds; a terminal write only lands while the operation still carries it.
    pub fn fence(&self) -> i64 {
        self.fence
    }

    pub fn is_cancelled(&self) -> bool {
        self.lost.load(Ordering::SeqCst) || self.jobs.worker_cancelled(self.operation_id)
    }

    pub fn renew_now(&self) -> Result<(), LeaseError> {
        let conn = self.database.lock();
        self.jobs
            .renew_owned(&conn, self.operation_id, &self.owner, self.fence)
    }

    pub fn set_stage(&self, stage: &str, progress: Option<f64>) -> Result<(), LeaseError> {
        let conn = self.database.lock();
        let now = self.jobs.clock.now();
        let expiry = format_utc(now + time::Duration::seconds(self.jobs.lease.lease_seconds));
        let changed = conn.execute(
            "UPDATE operations
                SET stage = ?1, progress = ?2, updated_at = ?3, lease_expires_at = ?4
              WHERE id = ?5 AND lease_owner = ?6 AND lease_fence = ?7
                AND state IN ('running', 'cancelling')",
            rusqlite::params![
                stage,
                progress,
                format_utc(now),
                expiry,
                self.operation_id.to_string(),
                self.owner,
                self.fence,
            ],
        )?;
        if changed == 1 {
            self.jobs
                .publish_operation(&conn, self.operation_id, "operation.progress", "info");
            Ok(())
        } else {
            Err(LeaseError::Lost)
        }
    }

    pub fn succeed(mut self, result: &serde_json::Value) -> Result<(), LeaseError> {
        self.finish("succeeded", None, Some(result))
    }

    pub fn fail(mut self, error_code: &str) -> Result<(), LeaseError> {
        self.finish("failed", Some(error_code), None)
    }

    /// Settle as succeeded and say whether it landed; a lost lease is already audited and logged.
    pub fn settle_succeeded(self, result: &serde_json::Value) -> bool {
        report(self.operation_id, self.succeed(result))
    }

    /// Settle as failed and say whether it landed; a lost lease is already audited and logged.
    pub fn settle_failed(self, error_code: &str) -> bool {
        report(self.operation_id, self.fail(error_code))
    }

    fn finish(
        &mut self,
        state: &str,
        error_code: Option<&str>,
        result: Option<&serde_json::Value>,
    ) -> Result<(), LeaseError> {
        self.stop_heartbeat();
        let mut conn = self.database.lock();
        self.jobs.finish_owned(
            &mut conn,
            self.operation_id,
            LeaseHolder {
                owner: &self.owner,
                fence: self.fence,
            },
            state,
            error_code,
            result,
        )?;
        self.finished = true;
        Ok(())
    }

    fn stop_heartbeat(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(heartbeat) = self.heartbeat.take() {
            let _ = heartbeat.join();
        }
    }
}

impl Drop for OperationLease {
    fn drop(&mut self) {
        self.stop_heartbeat();
        if !self.finished {
            // Retain ownership until expiry after panic so another worker cannot repeat partial side effects.
        }
    }
}

/// Say whether a terminal write landed, naming the operation when it did not.
fn report(operation_id: Uuid, outcome: Result<(), LeaseError>) -> bool {
    match outcome {
        Ok(()) => true,
        Err(error) => {
            tracing::warn!(%error, %operation_id, "an operation could not be settled by its worker");
            false
        }
    }
}

fn spawn_heartbeat(
    jobs: JobService,
    database: Arc<Mutex<Connection>>,
    operation_id: Uuid,
    owner: String,
    fence: i64,
    lost: Arc<AtomicBool>,
    stop: mpsc::Receiver<()>,
) -> std::thread::JoinHandle<()> {
    let database_path = database.lock().query_row(
        "SELECT file FROM pragma_database_list WHERE name = 'main'",
        [],
        |row| row.get::<_, String>(0),
    );
    let heartbeat_seconds = jobs.lease.heartbeat_seconds.max(1);
    std::thread::spawn(move || {
        let dedicated = database_path
            .ok()
            .filter(|path| !path.is_empty())
            .and_then(|path| Connection::open(path).ok());
        if let Some(conn) = &dedicated {
            let _ = conn.busy_timeout(StdDuration::from_secs(heartbeat_seconds));
        }
        loop {
            match stop.recv_timeout(StdDuration::from_secs(heartbeat_seconds)) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            let renewed = match &dedicated {
                Some(conn) => jobs.renew_owned(conn, operation_id, &owner, fence),
                None => jobs.renew_owned(&database.lock(), operation_id, &owner, fence),
            };
            if renewed.is_err() {
                lost.store(true, Ordering::SeqCst);
                jobs.signal_cancellation(operation_id);
                break;
            }
        }
    })
}

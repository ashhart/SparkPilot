use super::*;

pub struct MockVllmBackend {
    pub(super) shared: Arc<MockShared>,
    pub(super) runtime: tokio::runtime::Runtime,
}

pub(super) struct MockShared {
    /// Server name the stub advertises; set on first launch.
    pub(super) served_name: std::sync::Mutex<Option<String>>,
    /// Abort handle for the running axum server (current instance).
    pub(super) server: std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Bind the listener to one instance ID; stops for other IDs remain idempotent.
    pub(super) active_instance_id: std::sync::Mutex<Option<Uuid>>,

    /// Incremented every time an SSE client disconnects mid-stream.
    pub aborted_streams: AtomicUsize,
    /// Send one chunk then stall to test stream cancellation.
    pub stall_after_first: AtomicBool,
    /// Test-only latency before a non-streaming completion is returned.
    pub(super) non_stream_delay_millis: std::sync::atomic::AtomicU64,
    /// Force ephemeral port fallback to exercise reporting of the listener actually bound.
    pub(super) force_fallback_port: AtomicBool,
    /// Completion count (probes + real generations).
    pub completions: AtomicUsize,
    pub(super) text_tool_mode: AtomicBool,
    pub(super) omit_usage: AtomicBool,
    /// Number of engine container or stub launch attempts.
    pub(super) launches: AtomicUsize,
    pub(super) host_reserve: std::sync::atomic::AtomicU64,
    /// Test-only launch failures consumed before the stub binds a listener.
    pub(super) launch_failures_remaining: AtomicUsize,
    /// Text of the next injected launch failure; None keeps the generic message.
    pub(super) launch_failure_text: std::sync::Mutex<Option<String>>,
    /// Test control that holds the first-load image preparation boundary.
    pub(super) preparation_blocked: AtomicBool,
    /// Set once the backend reaches the image preparation boundary.
    pub(super) preparation_started: AtomicBool,
    /// Test control that holds readiness probing after container start.
    pub(super) readiness_blocked: AtomicBool,
    /// Set once the backend reaches the readiness probe boundary.
    pub(super) readiness_started: AtomicBool,
    /// Test control that holds container stop during replacement.
    pub(super) stop_blocked: AtomicBool,
    /// Set once the backend reaches container stop.
    pub(super) stop_started: AtomicBool,
    /// Test-only stop failures consumed before touching the running server.
    pub(super) stop_failures_remaining: AtomicUsize,
}

impl MockVllmBackend {
    /// Spin up the stub's own runtime; the server binds at `launch`.
    pub fn new() -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("mock vllm runtime");
        Self {
            shared: Arc::new(MockShared {
                served_name: std::sync::Mutex::new(None),
                server: std::sync::Mutex::new(None),
                active_instance_id: std::sync::Mutex::new(None),
                aborted_streams: AtomicUsize::new(0),
                stall_after_first: AtomicBool::new(false),
                non_stream_delay_millis: std::sync::atomic::AtomicU64::new(0),
                force_fallback_port: AtomicBool::new(false),
                completions: AtomicUsize::new(0),
                text_tool_mode: AtomicBool::new(false),
                omit_usage: AtomicBool::new(false),
                launches: AtomicUsize::new(0),
                host_reserve: std::sync::atomic::AtomicU64::new(0),
                launch_failures_remaining: AtomicUsize::new(0),
                launch_failure_text: std::sync::Mutex::new(None),
                preparation_blocked: AtomicBool::new(false),
                preparation_started: AtomicBool::new(false),
                readiness_blocked: AtomicBool::new(false),
                readiness_started: AtomicBool::new(false),
                stop_blocked: AtomicBool::new(false),
                stop_started: AtomicBool::new(false),
                stop_failures_remaining: AtomicUsize::new(0),
            }),
            runtime,
        }
    }

    pub fn crash_current_process(&self) {
        if let Some(server) = self.shared.server.lock().unwrap().take() {
            server.abort();
        }
        *self.shared.active_instance_id.lock().unwrap() = None;
    }

    pub fn aborted_streams(&self) -> usize {
        self.shared.aborted_streams.load(Ordering::Relaxed)
    }

    pub fn completions(&self) -> usize {
        self.shared.completions.load(Ordering::Relaxed)
    }

    /// Reproduce an engine launched without automatic tool choice or a native parser.
    pub fn set_text_tool_mode(&self, enabled: bool) {
        self.shared.text_tool_mode.store(enabled, Ordering::Relaxed);
    }

    pub fn set_omit_usage(&self, omit: bool) {
        self.shared.omit_usage.store(omit, Ordering::Relaxed);
    }

    pub fn set_host_reserve(&self, bytes: u64) {
        self.shared.host_reserve.store(bytes, Ordering::Relaxed);
    }

    pub fn launches(&self) -> usize {
        self.shared.launches.load(Ordering::SeqCst)
    }

    pub fn fail_next_launch(&self) {
        self.shared
            .launch_failures_remaining
            .fetch_add(1, Ordering::SeqCst);
    }

    /// Fail the next launch with the text a privileged helper rejection would carry.
    pub fn fail_next_launch_with(&self, text: &str) {
        *self
            .shared
            .launch_failure_text
            .lock()
            .expect("launch failure text lock") = Some(text.to_owned());
        self.fail_next_launch();
    }

    pub fn set_stall_after_first(&self, stall: bool) {
        self.shared
            .stall_after_first
            .store(stall, Ordering::Relaxed);
    }

    pub fn set_non_stream_delay(&self, delay: Duration) {
        self.shared.non_stream_delay_millis.store(
            delay.as_millis().try_into().unwrap_or(u64::MAX),
            Ordering::Relaxed,
        );
    }

    pub fn set_force_fallback_port(&self, force: bool) {
        self.shared
            .force_fallback_port
            .store(force, Ordering::Relaxed);
    }

    pub fn set_preparation_blocked(&self, blocked: bool) {
        self.shared
            .preparation_blocked
            .store(blocked, Ordering::SeqCst);
    }

    pub fn preparation_started(&self) -> bool {
        self.shared.preparation_started.load(Ordering::SeqCst)
    }

    pub fn set_readiness_blocked(&self, blocked: bool) {
        self.shared
            .readiness_blocked
            .store(blocked, Ordering::SeqCst);
    }

    pub fn readiness_started(&self) -> bool {
        self.shared.readiness_started.load(Ordering::SeqCst)
    }

    pub fn set_stop_blocked(&self, blocked: bool) {
        self.shared.stop_blocked.store(blocked, Ordering::SeqCst);
    }

    pub fn stop_started(&self) -> bool {
        self.shared.stop_started.load(Ordering::SeqCst)
    }

    pub fn fail_next_stop(&self) {
        self.shared
            .stop_failures_remaining
            .fetch_add(1, Ordering::SeqCst);
    }
}

impl Default for MockVllmBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl EngineBackend for MockVllmBackend {
    async fn prepare(
        &self,
        _instance: &EngineInstance,
    ) -> Result<EngineImagePreparation, BackendError> {
        self.shared
            .preparation_started
            .store(true, Ordering::SeqCst);
        while self.shared.preparation_blocked.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        Ok(EngineImagePreparation::AlreadyAvailable)
    }

    async fn launch_accounted(
        &self,
        instance: &EngineInstance,
    ) -> Result<(u16, u64), BackendError> {
        self.launch(instance)
            .await
            .map(|port| (port, self.shared.host_reserve.load(Ordering::Relaxed)))
    }

    async fn launch(&self, instance: &EngineInstance) -> Result<u16, BackendError> {
        self.shared.launches.fetch_add(1, Ordering::SeqCst);
        if self
            .shared
            .launch_failures_remaining
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| {
                remaining.checked_sub(1)
            })
            .is_ok()
        {
            let text = self
                .shared
                .launch_failure_text
                .lock()
                .expect("launch failure text lock")
                .take();
            return Err(BackendError(
                text.unwrap_or_else(|| "injected launch failure".into()),
            ));
        }
        *self.shared.served_name.lock().expect("served lock") = Some(instance.served_name.clone());
        let addr: SocketAddr = format!("127.0.0.1:{}", instance.internal_port)
            .parse()
            .map_err(|e| BackendError(format!("bad addr: {e}")))?;
        // Use a free loopback port when parallel tests collide in the derived port range.
        let listener = if self.shared.force_fallback_port.load(Ordering::Relaxed) {
            StdTcpListener::bind(("127.0.0.1", 0))
        } else {
            StdTcpListener::bind(addr).or_else(|_| StdTcpListener::bind(("127.0.0.1", 0)))
        }
        .map_err(|e| BackendError(format!("loopback bind failed: {e}")))?;
        listener
            .set_nonblocking(true)
            .map_err(|e| BackendError(format!("nonblocking: {e}")))?;
        let port = listener
            .local_addr()
            .map_err(|e| BackendError(e.to_string()))?
            .port();

        let shared = self.shared.clone();
        let app = mock_router(shared.clone());
        let (tx, rx) = oneshot::channel();
        let handle = self.runtime.spawn(async move {
            let listener = match tokio::net::TcpListener::from_std(listener) {
                Ok(l) => l,
                Err(e) => {
                    let _ = tx.send(Err(BackendError(format!("from_std: {e}"))));
                    return;
                }
            };
            let _ = tx.send(Ok(port));
            axum::serve(listener, app).await.ok();
        });
        *self.shared.server.lock().expect("server lock") = Some(handle);
        *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock") = Some(instance.instance_id);
        let bound = rx
            .await
            .map_err(|e| BackendError(format!("launch channel: {e}")))?;
        bound?;
        Ok(port)
    }

    async fn stop(&self, instance: &EngineInstance, _force: bool) -> Result<(), BackendError> {
        self.shared.stop_started.store(true, Ordering::SeqCst);
        if *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock")
            != Some(instance.instance_id)
        {
            return Ok(());
        }
        if self
            .shared
            .stop_failures_remaining
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| {
                remaining.checked_sub(1)
            })
            .is_ok()
        {
            return Err(BackendError("injected stop failure".into()));
        }
        while self.shared.stop_blocked.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let handle = self.shared.server.lock().expect("server lock").take();
        if let Some(handle) = handle {
            handle.abort();
            // Wait for aborted listener shutdown before stop returns so the mock honors production completion semantics.
            let _ = handle.await;
        }
        *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock") = None;
        Ok(())
    }

    async fn reconcile_instance(
        &self,
        instance_id: Uuid,
        _external_workload_id: Option<&str>,
    ) -> Result<(), BackendError> {
        self.shared.stop_started.store(true, Ordering::SeqCst);
        if *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock")
            != Some(instance_id)
        {
            return Ok(());
        }
        while self.shared.stop_blocked.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let handle = self.shared.server.lock().expect("server lock").take();
        if let Some(handle) = handle {
            handle.abort();
            let _ = handle.await;
        }
        *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock") = None;
        Ok(())
    }

    async fn is_running(&self, instance: &EngineInstance) -> bool {
        if *self
            .shared
            .active_instance_id
            .lock()
            .expect("active instance lock")
            != Some(instance.instance_id)
        {
            return false;
        }
        // The handle being present and the port still accepting both count.
        if self.shared.server.lock().expect("server lock").is_some() {
            return true;
        }
        std::net::TcpStream::connect(("127.0.0.1", instance.internal_port)).is_ok()
    }

    async fn has_exited(&self, instance: &EngineInstance) -> bool {
        !self.is_running(instance).await
    }

    async fn health(&self, instance: &EngineInstance) -> Result<bool, BackendError> {
        self.shared.readiness_started.store(true, Ordering::SeqCst);
        while self.shared.readiness_blocked.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let url = format!("http://127.0.0.1:{}/health", instance.internal_port);
        let client = reqwest::Client::new();
        let result = tokio::time::timeout(Duration::from_secs(2), client.get(&url).send()).await;
        Ok(result.is_ok_and(|r| r.is_ok_and(|r| r.status().is_success())))
    }

    async fn list_model_names(
        &self,
        instance: &EngineInstance,
    ) -> Result<Vec<String>, BackendError> {
        let url = format!("http://127.0.0.1:{}/v1/models", instance.internal_port);
        let client = reqwest::Client::new();
        let resp = client
            .get(&url)
            .send()
            .await
            .map_err(|e| BackendError(format!("models probe: {e}")))?;
        let body: Value = resp
            .json()
            .await
            .map_err(|e| BackendError(format!("models parse: {e}")))?;
        let data = body
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        Ok(data
            .iter()
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned))
            .collect())
    }

    async fn probe_completion(&self, instance: &EngineInstance) -> Result<(), BackendError> {
        let url = format!(
            "http://127.0.0.1:{}/v1/chat/completions",
            instance.internal_port
        );
        let client = reqwest::Client::new();
        let body = json!({
            "model": instance.served_name,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 2,
            "stream": false,
        });
        let resp = client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| BackendError(format!("completion probe: {e}")))?;
        if resp.status() != StatusCode::OK {
            return Err(BackendError(format!(
                "completion probe status {}",
                resp.status()
            )));
        }
        Ok(())
    }

    fn probe_container_runtime(&self) -> ContainerRuntimeReport {
        ContainerRuntimeReport::new(
            "mock",
            false,
            Some("in-process vLLM stub; no host container runtime is used".into()),
        )
    }
}

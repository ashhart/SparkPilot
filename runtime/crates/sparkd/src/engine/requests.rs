use super::*;

pub(super) struct RequestAdmission<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) db: &'a Mutex<rusqlite::Connection>,
}

impl RequestAdmission<'_> {
    /// Hold engine admission while committing the reservation; callbacks must acquire storage after the engine lock.
    pub(super) fn with_pool_admission<T>(
        &self,
        admit: impl FnOnce(&EngineInstance, u32) -> Result<T, crate::pool::PoolError>,
    ) -> Result<T, crate::pool::PoolError> {
        let core = self.inner.lock();
        let instance = core.instance.as_ref().ok_or(EngineError::NotLoaded)?;
        if core.transitioning || !core.state.accepts_requests() {
            return Err(EngineError::NotReady.into());
        }
        admit(
            instance,
            core.active_requests
                .saturating_sub(core.pool_active_requests),
        )
    }

    /// Transfer a durable reservation directly into execution; only the execution worker may release its slot.
    pub(super) fn begin_pool_request<T>(
        &self,
        accept: impl FnOnce(&EngineInstance) -> Result<T, crate::pool::PoolError>,
        make_ticket: impl FnOnce(Uuid) -> RequestTicket,
    ) -> Result<(T, RequestTicket, EngineUpstream), crate::pool::PoolError> {
        let mut core = self.inner.lock();
        let instance = core.instance.as_ref().ok_or(EngineError::NotLoaded)?;
        if core.transitioning || !core.state.accepts_requests() {
            return Err(EngineError::NotReady.into());
        }
        let accepted = accept(instance)?;
        let instance_id = instance.instance_id;
        let upstream = EngineUpstream {
            host_port: instance.internal_port,
            api_key: instance.api_key.clone(),
            model_id: instance.model_id.clone(),
            served_name: instance.served_name.clone(),
        };
        core.active_requests += 1;
        core.pool_active_requests += 1;
        core.last_activity = Instant::now();
        Ok((accepted, make_ticket(instance_id), upstream))
    }

    pub(super) fn admit_generation(
        &self,
        requested: Option<&str>,
        make_ticket: impl FnOnce(Uuid) -> RequestTicket,
    ) -> Result<(RequestTicket, EngineUpstream), EngineError> {
        let (host_port, api_key, model_id, served_name, instance_id) = {
            let mut core = self.inner.lock();
            let Some(instance) = &core.instance else {
                return Err(EngineError::NotLoaded);
            };
            if core.transitioning {
                return Err(EngineError::NotReady);
            }
            // Check Draining before the Ready gate so callers receive the distinct retryable ENGINE_DRAINING error.
            if core.state == EngineState::Draining {
                return Err(EngineError::Draining);
            }
            if !core.state.accepts_requests() {
                return Err(EngineError::NotReady);
            }
            if let Some(requested) = requested
                && requested != instance.served_name
                && requested != instance.model_id
            {
                return Err(EngineError::NotTheLoadedModel {
                    requested: crate::api_error::abbreviated(requested),
                    served: instance.served_name.clone(),
                });
            }
            // Pool and direct requests share the profile ceiling; unknown durable outcomes remain charged after restart.
            if let Some(charged) =
                crate::pool::engine_capacity_charge(&self.db.lock()).map_err(|_| {
                    EngineError::Admission(
                        "POOL_STORAGE_UNAVAILABLE",
                        "Pool capacity could not be checked".into(),
                    )
                })?
                && charged.saturating_add(
                    core.active_requests
                        .saturating_sub(core.pool_active_requests),
                ) >= instance.profile.max_sequences
            {
                return Err(EngineError::Admission(
                    "POOL_CAPACITY_BUSY",
                    "The loaded deployment has no unreserved serving slot".into(),
                ));
            }
            let upstream = (
                instance.internal_port,
                instance.api_key.clone(),
                instance.model_id.clone(),
                instance.served_name.clone(),
                instance.instance_id,
            );
            core.active_requests += 1;
            core.last_activity = Instant::now();
            upstream
        };
        let upstream = EngineUpstream {
            host_port,
            api_key,
            model_id,
            served_name,
        };
        let ticket = make_ticket(instance_id);
        Ok((ticket, upstream))
    }

    pub(super) fn end_request(&self, pool: bool, instance_id: Uuid) {
        let mut core = self.inner.lock();
        if core.instance.as_ref().map(|instance| instance.instance_id) != Some(instance_id) {
            return;
        }
        core.active_requests = core.active_requests.saturating_sub(1);
        if pool {
            core.pool_active_requests = core.pool_active_requests.saturating_sub(1);
        }
        core.last_activity = Instant::now();
    }

    pub(super) fn record_metrics(&self, ttft_ms: f64, tokens_per_second: Option<f64>) {
        let mut core = self.inner.lock();
        core.last_ttft_ms = Some(ttft_ms);
        if let Some(tps) = tokens_per_second {
            core.last_tokens_per_second = Some(tps);
        }
    }
}

/// Release generation accounting on drop, including proxy client disconnects.
pub struct RequestTicket {
    manager: Arc<EngineManager>,
    started: SystemTime,
    ttft_ms: Option<f64>,
    finished: bool,
    pool: bool,
    instance_id: Uuid,
}

impl Drop for RequestTicket {
    fn drop(&mut self) {
        if !self.finished {
            self.manager.end_request(self.pool, self.instance_id);
        }
    }
}

impl RequestTicket {
    pub(super) fn new(manager: Arc<EngineManager>, pool: bool, instance_id: Uuid) -> Self {
        Self {
            manager,
            started: SystemTime::now(),
            ttft_ms: None,
            finished: false,
            pool,
            instance_id,
        }
    }

    /// Elapsed wall time since the request began (for throughput math).
    pub fn elapsed(&self) -> Option<Duration> {
        self.started.elapsed().ok()
    }

    /// Measured TTFT in milliseconds, when recorded.
    pub fn ttft_ms(&self) -> Option<f64> {
        self.ttft_ms
    }

    /// First upstream frame forwarded — measures TTFT and records it.
    pub fn note_first_frame(&mut self) {
        if self.ttft_ms.is_none()
            && let Ok(elapsed) = self.started.elapsed()
        {
            self.ttft_ms = Some(elapsed.as_secs_f64() * 1000.0);
            self.manager.record_metrics(self.ttft_ms.unwrap(), None);
        }
    }

    /// Explicit completion with measured throughput.
    pub fn note_complete(&mut self, tokens_per_second: Option<f64>) {
        self.manager
            .record_metrics(self.ttft_ms.unwrap_or(0.0), tokens_per_second);
        self.finished = true;
        self.manager.end_request(self.pool, self.instance_id);
    }
}

/// Upstream connection facts handed to the proxy (never recipe details).
#[derive(Clone)]
pub struct EngineUpstream {
    pub host_port: u16,
    pub api_key: String,
    pub model_id: String,
    pub served_name: String,
}

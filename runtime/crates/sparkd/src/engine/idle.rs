use super::*;

pub(super) struct IdleWatch<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) stop: stop::StopFlow<'a>,
}

impl IdleWatch<'_> {
    pub(super) fn idle_watch_configuration(&self) -> Option<(Uuid, u64, Duration)> {
        let core = self.inner.lock();
        let instance = core.instance.as_ref()?;
        let configured = self
            .db
            .lock()
            .query_row(
                "SELECT p.idle_policy, t.timeout_seconds FROM model_idle_policies p
                 LEFT JOIN model_idle_timeouts t ON p.model_id = t.model_id AND p.profile_id = t.profile_id
                 WHERE p.model_id = ?1 AND p.profile_id = ?2",
                rusqlite::params![instance.model_id, instance.profile_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<u64>>(1)?)),
            )
            .optional()
            .unwrap_or(None)
            .unwrap_or_else(|| (instance.profile.idle_policy.clone(), None));
        idle_policy_timeout(&configured.0)
            .map(|named| configured.1.map(Duration::from_secs).unwrap_or(named))
            .map(|timeout| (instance.instance_id, core.idle_generation, timeout))
    }

    pub(super) fn idle_watch(&self, instance_id: Uuid, generation: u64, timeout: Duration) {
        self.idle_watch_with(
            instance_id,
            generation,
            timeout,
            std::thread::sleep,
            |last| last.elapsed(),
        );
    }

    fn idle_watch_with(
        &self,
        instance_id: Uuid,
        generation: u64,
        timeout: Duration,
        mut sleep: impl FnMut(Duration),
        mut elapsed: impl FnMut(Instant) -> Duration,
    ) {
        loop {
            let remaining = {
                let core = self.inner.lock();
                if core.idle_generation != generation
                    || core.transitioning
                    || core.instance.as_ref().map(|instance| instance.instance_id)
                        != Some(instance_id)
                {
                    return;
                }
                timeout.saturating_sub(elapsed(core.last_activity))
            };
            if !remaining.is_zero() {
                sleep(remaining.min(Duration::from_secs(30)));
                continue;
            }
            let instance = {
                let mut core = self.inner.lock();
                // Exit when superseded, transitioning or no longer Ready.
                if core.idle_generation != generation
                    || core.transitioning
                    || core.state != EngineState::Ready
                {
                    return;
                }
                // §31.9: a reservation the caller can still execute is durable work the idle policy must not destroy.
                let durable = core.instance.as_ref().is_some_and(|instance| {
                    crate::pool::durable_work_outstanding(&self.db.lock(), instance.instance_id)
                        .unwrap_or(true)
                });
                // Rearm when activity races the deadline or requests remain active, so the idle watchdog stays armed.
                if durable || core.active_requests != 0 || elapsed(core.last_activity) < timeout {
                    None
                } else {
                    let Some(instance) = core.instance.clone() else {
                        return;
                    };
                    core.transitioning = true;
                    core.state = EngineState::Stopping;
                    Some(instance)
                }
            };
            let Some(instance) = instance else {
                sleep(Duration::from_secs(1));
                continue;
            };
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("idle-policy engine runtime");
            runtime.block_on(self.stop.idle_stop_worker(instance));
            return;
        }
    }
}

#[cfg(test)]
#[path = "idle_tests.rs"]
mod tests;

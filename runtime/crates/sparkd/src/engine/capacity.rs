use super::*;

pub(super) struct Capacity<'a> {
    pub(super) inner: &'a Mutex<EngineCore>,
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) guard: &'a Mutex<Option<Arc<crate::guard::MemoryGuardService>>>,
    pub(super) telemetry: &'a dyn SystemMonitor,
    pub(super) minimum_system_reserve_bytes: u64,
    pub(super) memory_recovery_timeout: Duration,
}

impl Capacity<'_> {
    /// Reserve the stricter of the appliance policy and signed recipe requirement.
    pub(super) fn system_reserve_bytes(&self, recipe: &ModelRecipe) -> u64 {
        recipe
            .memory
            .minimum_system_reserve_bytes
            .max(self.minimum_system_reserve_bytes)
    }

    /// Canonical pre-launch admission checks guard pressure, stored unsafe status, measured peak and headroom.
    pub(super) fn admission_evidence(
        &self,
        recipe: &ModelRecipe,
        profile: &Profile,
        replace_active: bool,
    ) -> Result<AdmissionEvidence, EngineError> {
        let current_available = self.telemetry.system().unified_memory_available_bytes;
        let available = if replace_active {
            self.replacement_available_memory_bytes(current_available)
        } else {
            current_available
        };
        self.admission_evidence_with_available(recipe, profile, available)
    }

    /// Project replacement recovery from the observed pre-load baseline; apply rechecks actual memory after stop.
    pub(super) fn replacement_available_memory_bytes(&self, current_available: u64) -> u64 {
        self.inner
            .lock()
            .instance
            .as_ref()
            .map(|instance| instance.memory_baseline_bytes)
            .unwrap_or(current_available)
            .max(current_available)
    }

    pub(super) fn admission_evidence_with_available(
        &self,
        recipe: &ModelRecipe,
        profile: &Profile,
        available: u64,
    ) -> Result<AdmissionEvidence, EngineError> {
        let signals = MemorySignals::calm(available).with_available(available);
        let pressure = self
            .guard
            .lock()
            .as_ref()
            .map(|g| g.reading().state)
            .unwrap_or(PressureState::Normal);
        let conn = self.db.lock();
        let environment = crate::guard::recipe_environment(recipe);
        let measured = crate::guard::measured_peak(&conn, recipe.id(), &profile.id, &environment)
            .map_err(|e| EngineError::Invalid(e.to_string()))?;
        let unsafe_flag = crate::guard::profile_is_unsafe(&conn, recipe.id(), &profile.id)
            .map_err(|e| EngineError::Invalid(e.to_string()))?;
        drop(conn);
        let system_reserve_bytes = self.system_reserve_bytes(recipe);
        // ADR-043: budget what the profile's arithmetic says it takes; measurement only ever raises that.
        let reservation = recipe.reservation(profile);
        let reservation_bytes = recipe.profile_reservation_bytes(profile);
        let required_memory_bytes = measured.unwrap_or(0).max(reservation_bytes);
        let budget = available.saturating_sub(system_reserve_bytes);
        let decision = check_admission(&AdmissionRequest {
            expected_peak_bytes: reservation_bytes,
            measured_peak_bytes: measured,
            signals,
            pressure,
            system_reserve_bytes,
            profile_unsafe: unsafe_flag,
        });
        let expected_headroom_bytes = available
            .saturating_sub(system_reserve_bytes)
            .saturating_sub(required_memory_bytes);
        Ok(AdmissionEvidence {
            required_memory_bytes,
            available_memory_bytes: available,
            system_reserve_bytes,
            expected_headroom_bytes,
            reservation,
            max_context_now: recipe.max_context_that_fits(profile, budget),
            max_sequences_now: recipe.max_sequences_that_fit(profile, budget),
            pressure,
            decision,
        })
    }

    pub(super) fn admit(
        &self,
        recipe: &ModelRecipe,
        profile: &Profile,
        replace_active: bool,
    ) -> Result<u64, EngineError> {
        let evidence = self.admission_evidence(recipe, profile, replace_active)?;
        match evidence.decision {
            AdmissionDecision::Allow { .. } => Ok(evidence.available_memory_bytes),
            AdmissionDecision::DenyInsufficientMemory => Err(EngineError::Admission(
                "MODEL_INSUFFICIENT_MEMORY",
                "insufficient unified memory for profile".to_owned(),
            )),
            AdmissionDecision::DenyPressureActive => Err(EngineError::Admission(
                "MEMORY_PRESSURE_ACTIVE",
                "memory guard is not Normal; wait for pressure to clear".to_owned(),
            )),
            AdmissionDecision::DenyProfileUnsafe => Err(EngineError::Admission(
                "MODEL_PROFILE_UNSAFE",
                "profile marked unsafe after a memory failure; re-enable explicitly".to_owned(),
            )),
        }
    }

    /// Record what the recovery check saw so the outcome can be shown, not only judged.
    pub(super) fn unload_evidence(
        &self,
        instance: &EngineInstance,
        recovered: bool,
    ) -> super::state::UnloadEvidence {
        super::state::UnloadEvidence {
            model_id: instance.model_id.clone(),
            memory_recovered: recovered,
            baseline_bytes: instance.memory_baseline_bytes,
            available_bytes: self.telemetry.system().unified_memory_available_bytes,
            finished_at: crate::store::now_iso8601(),
        }
    }

    pub(super) fn memory_recovered(&self, instance: &EngineInstance) -> bool {
        let available = self.telemetry.system().unified_memory_available_bytes;
        available
            >= instance
                .memory_baseline_bytes
                .saturating_sub(MEMORY_RECOVERY_TOLERANCE_BYTES)
    }

    pub(super) async fn wait_for_memory_recovery(&self, instance: &EngineInstance) -> bool {
        let deadline = tokio::time::Instant::now() + self.memory_recovery_timeout;
        loop {
            if self.memory_recovered(instance) {
                return true;
            }
            let now = tokio::time::Instant::now();
            if now >= deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(250).min(deadline - now)).await;
        }
    }
}

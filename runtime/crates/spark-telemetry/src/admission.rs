//! Gate model loads on guard state, declared or measured peak memory, and the required system reserve (§33.1).

use crate::pressure::PressureState;
use crate::signals::MemorySignals;

/// Default 128 GiB-node reserve for the OS, page cache and runtime services.
pub const DEFAULT_SYSTEM_RESERVE_BYTES: u64 = 22_355_775_488;

#[derive(Debug, Clone, PartialEq)]
pub struct AdmissionRequest {
    /// Recipe-declared peak for the profile being loaded.
    pub expected_peak_bytes: u64,
    /// Measured peak from `profile_measurements`, when history exists.
    pub measured_peak_bytes: Option<u64>,
    pub signals: MemorySignals,
    pub pressure: PressureState,
    pub system_reserve_bytes: u64,
    /// The profile was marked unsafe after a pressure failure (§33.5.7).
    pub profile_unsafe: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdmissionDecision {
    /// Cleared to load; reports the headroom left after the peak.
    Allow { headroom_bytes: u64 },
    /// Peak does not fit the current budget.
    DenyInsufficientMemory,
    /// Reject loads while the guard reports Warning or a more severe state.
    DenyPressureActive,
    /// Profile marked unsafe; requires explicit user action (§33.6).
    DenyProfileUnsafe,
}

impl AdmissionDecision {
    pub fn is_allowed(self) -> bool {
        matches!(self, AdmissionDecision::Allow { .. })
    }

    /// Maps onto `MODEL_INSUFFICIENT_MEMORY`-style client guidance.
    pub fn error_code(self) -> Option<&'static str> {
        match self {
            AdmissionDecision::Allow { .. } => None,
            AdmissionDecision::DenyInsufficientMemory => Some("MODEL_INSUFFICIENT_MEMORY"),
            AdmissionDecision::DenyPressureActive => Some("MEMORY_PRESSURE_ACTIVE"),
            AdmissionDecision::DenyProfileUnsafe => Some("MODEL_PROFILE_UNSAFE"),
        }
    }
}

/// Use the larger declared or measured peak because recipes may underestimate memory.
pub fn check_admission(request: &AdmissionRequest) -> AdmissionDecision {
    if request.profile_unsafe {
        return AdmissionDecision::DenyProfileUnsafe;
    }

    if request.pressure != PressureState::Normal {
        return AdmissionDecision::DenyPressureActive;
    }

    let peak = request
        .measured_peak_bytes
        .unwrap_or(0)
        .max(request.expected_peak_bytes);
    let budget = request
        .signals
        .available_bytes
        .saturating_sub(request.system_reserve_bytes);

    if peak > budget {
        return AdmissionDecision::DenyInsufficientMemory;
    }

    AdmissionDecision::Allow {
        headroom_bytes: budget - peak,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::MemorySignals;

    const GIB: u64 = 1024 * 1024 * 1024;

    fn request(available_gib: u64, peak_gib: u64) -> AdmissionRequest {
        AdmissionRequest {
            expected_peak_bytes: peak_gib * GIB,
            measured_peak_bytes: None,
            signals: MemorySignals::calm(128 * GIB).with_available(available_gib * GIB),
            pressure: PressureState::Normal,
            system_reserve_bytes: 21 * GIB,
            profile_unsafe: false,
        }
    }

    #[test]
    fn allows_when_headroom_covers_the_peak() {
        let decision = check_admission(&request(100, 40));
        assert_eq!(
            decision,
            AdmissionDecision::Allow {
                headroom_bytes: 39 * GIB
            }
        );
    }

    #[test]
    fn denies_when_the_reserve_would_be_eaten() {
        let decision = check_admission(&request(50, 40));
        assert_eq!(decision, AdmissionDecision::DenyInsufficientMemory);
        assert_eq!(decision.error_code(), Some("MODEL_INSUFFICIENT_MEMORY"));
    }

    #[test]
    fn measured_peak_overrides_an_optimistic_recipe() {
        let mut req = request(100, 40);
        req.measured_peak_bytes = Some(85 * GIB);
        assert_eq!(
            check_admission(&req),
            AdmissionDecision::DenyInsufficientMemory
        );
    }

    #[test]
    fn any_non_normal_pressure_blocks_new_loads() {
        for pressure in [
            PressureState::Warning,
            PressureState::Draining,
            PressureState::Critical,
            PressureState::Emergency,
            PressureState::Recovering,
        ] {
            let mut req = request(100, 40);
            req.pressure = pressure;
            assert_eq!(
                check_admission(&req),
                AdmissionDecision::DenyPressureActive,
                "{pressure:?} must block admission"
            );
        }
    }

    #[test]
    fn unsafe_profiles_require_explicit_user_action() {
        let mut req = request(100, 40);
        req.profile_unsafe = true;
        assert_eq!(check_admission(&req), AdmissionDecision::DenyProfileUnsafe);
    }
}

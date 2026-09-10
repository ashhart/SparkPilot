//! Classify pressure thresholds; the pressure state machine adds dwell time and hysteresis.

use crate::signals::{MemoryPolicy, MemorySignals};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MemoryAction {
    Continue,
    Warn,
    StopAdmissions,
    GracefulUnload,
    EmergencyStop,
}

/// Rank actions on the §33.3 ladder; Recovering is a separate state without its own action.
impl MemoryAction {
    pub fn rank(self) -> u32 {
        match self {
            MemoryAction::Continue => 0,
            MemoryAction::Warn => 1,
            MemoryAction::StopAdmissions => 2,
            MemoryAction::GracefulUnload => 3,
            MemoryAction::EmergencyStop => 4,
        }
    }
}

/// Project ten seconds ahead to distinguish an imminent floor crossing from a safe large allocation.
const CLIFF_HORIZON_SECONDS: u64 = 10;

/// Classify current thresholds with velocity disabled; callers must explicitly enable the load-sensitive cliff rule.
pub fn classify(snapshot: &MemorySignals, policy: &MemoryPolicy) -> MemoryAction {
    classify_with_velocity(snapshot, policy, false)
}

/// Optionally apply velocity; during model loading only the available-memory floor and kernel OOM remain immediate.
pub fn classify_with_velocity(
    snapshot: &MemorySignals,
    policy: &MemoryPolicy,
    velocity_counts: bool,
) -> MemoryAction {
    let available = snapshot.available_bytes;

    // Require the observed fall to project a floor crossing within the horizon; loading alone can consume memory rapidly.
    let projected_available = available.saturating_sub(
        snapshot
            .available_drop_bytes_per_second
            .saturating_mul(CLIFF_HORIZON_SECONDS),
    );
    // Apply velocity only inside the warning band because serving and page-cache activity can move gigabytes at safe levels.
    let falling_off_a_cliff = velocity_counts
        && available < policy.warning_available_bytes
        && snapshot.available_drop_bytes_per_second > policy.emergency_drop_bytes_per_second
        && projected_available < policy.emergency_available_bytes;
    if snapshot.kernel_oom_event
        || available < policy.emergency_available_bytes
        || falling_off_a_cliff
    {
        return MemoryAction::EmergencyStop;
    }

    if available < policy.critical_available_bytes
        || snapshot.psi_full_avg10 > policy.critical_psi_full_avg10
    {
        return MemoryAction::GracefulUnload;
    }

    if available < policy.draining_available_bytes()
        || snapshot.psi_some_avg10 > policy.warning_psi_some_avg10
    {
        return MemoryAction::StopAdmissions;
    }

    if available < policy.warning_available_bytes {
        return MemoryAction::Warn;
    }

    MemoryAction::Continue
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signals(available_gib: f64) -> MemorySignals {
        let total = 128_u64 << 30;
        MemorySignals {
            available_bytes: (available_gib * 1024.0 * 1024.0 * 1024.0) as u64,
            total_bytes: total,
            psi_some_avg10: 0.0,
            psi_full_avg10: 0.0,
            available_drop_bytes_per_second: 0,
            kernel_oom_event: false,
            gpu_celsius: None,
            cpu_celsius: None,
        }
    }

    #[test]
    fn classifies_the_ladder() {
        let policy = MemoryPolicy::default();
        assert_eq!(classify(&signals(40.0), &policy), MemoryAction::Continue);
        assert_eq!(classify(&signals(15.0), &policy), MemoryAction::Warn);
        assert_eq!(
            classify(&signals(12.0), &policy),
            MemoryAction::StopAdmissions
        );
        assert_eq!(
            classify(&signals(8.0), &policy),
            MemoryAction::GracefulUnload
        );
        assert_eq!(
            classify(&signals(5.0), &policy),
            MemoryAction::EmergencyStop
        );
    }

    #[test]
    fn psi_escalates_without_available_pressure() {
        let policy = MemoryPolicy::default();
        let mut s = signals(60.0);
        s.psi_some_avg10 = 0.4;
        assert_eq!(classify(&s, &policy), MemoryAction::StopAdmissions);
        s.psi_some_avg10 = 0.0;
        s.psi_full_avg10 = 0.2;
        assert_eq!(classify(&s, &policy), MemoryAction::GracefulUnload);
    }

    #[test]
    fn kernel_oom_and_velocity_are_immediate_emergencies() {
        let policy = MemoryPolicy::default();
        // Enable velocity explicitly; classify() must remain safe for callers observing a model load.
        let cliff = |s: &MemorySignals| classify_with_velocity(s, &policy, true);

        let mut s = signals(60.0);
        s.kernel_oom_event = true;
        assert_eq!(classify(&s, &policy), MemoryAction::EmergencyStop);

        // A 5 GiB/s fall from 60 GiB remains above the emergency floor over the ten-second horizon.
        s.kernel_oom_event = false;
        s.available_drop_bytes_per_second = 5_u64 << 30;
        assert_eq!(cliff(&s), MemoryAction::Continue);

        // Velocity inside the warning band must qualify for the projected cliff check.
        let mut falling = signals(12.0);
        falling.available_drop_bytes_per_second = 5_u64 << 30;
        assert_eq!(cliff(&falling), MemoryAction::EmergencyStop);
        // With velocity disabled for loading, classification uses the observed level alone.
        assert_ne!(classify(&falling, &policy), MemoryAction::EmergencyStop);

        // Serving-time memory swings with 30 GB free must not trigger the cliff rule.
        let mut serving = signals(28.0);
        serving.available_drop_bytes_per_second = 5_u64 << 30;
        assert_eq!(cliff(&serving), MemoryAction::Continue);
    }

    /// A 30B model load with 120 GB free must not trigger EmergencyStop merely because allocation is fast.
    #[test]
    fn a_large_model_load_is_not_an_emergency() {
        let policy = MemoryPolicy::default();
        let mut loading = signals(112.0);
        loading.available_drop_bytes_per_second = 6_u64 << 30;
        loading.psi_full_avg10 = 0.05;
        assert_eq!(classify(&loading, &policy), MemoryAction::Continue);
    }
}

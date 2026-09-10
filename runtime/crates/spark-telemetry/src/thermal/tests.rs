use super::*;

fn at(celsius: f64) -> ThermalSignals {
    ThermalSignals {
        gpu_celsius: Some(celsius),
        cpu_celsius: None,
    }
}

fn secs(value: u64) -> Duration {
    Duration::from_secs(value)
}

#[test]
fn classifies_the_ladder() {
    let policy = ThermalPolicy::default();
    assert_eq!(classify_thermal(&at(40.0), &policy), ThermalState::Nominal);
    assert_eq!(classify_thermal(&at(78.0), &policy), ThermalState::Warm);
    assert_eq!(classify_thermal(&at(85.0), &policy), ThermalState::Hot);
    assert_eq!(classify_thermal(&at(95.0), &policy), ThermalState::Critical);
}

#[test]
fn absent_sensors_are_unknown_and_never_act() {
    let policy = ThermalPolicy::default();
    let nothing = ThermalSignals::default();
    assert_eq!(classify_thermal(&nothing, &policy), ThermalState::Unknown);
    // Absent temperature must not produce a new thermal action.
    assert_eq!(ThermalState::Unknown.action(), MemoryAction::Continue);
}

#[test]
fn the_hotter_of_the_two_sensors_drives_the_ladder() {
    let policy = ThermalPolicy::default();
    let signals = ThermalSignals {
        gpu_celsius: Some(60.0),
        cpu_celsius: Some(86.0),
    };
    assert_eq!(signals.hottest_celsius(), Some(86.0));
    assert_eq!(classify_thermal(&signals, &policy), ThermalState::Hot);
}

#[test]
fn thermal_never_demands_an_emergency_stop() {
    // Heat alone may trigger graceful unload but never the memory-only emergency stop.
    let policy = ThermalPolicy::default();
    assert_eq!(
        classify_thermal(&at(120.0), &policy),
        ThermalState::Critical
    );
    assert_eq!(
        ThermalState::Critical.action(),
        MemoryAction::GracefulUnload
    );
    for state in [
        ThermalState::Unknown,
        ThermalState::Nominal,
        ThermalState::Warm,
        ThermalState::Hot,
        ThermalState::Critical,
    ] {
        assert_ne!(state.action(), MemoryAction::EmergencyStop);
    }
}

#[test]
fn a_single_hot_sample_does_not_escalate() {
    let mut machine = ThermalStateMachine::new(ThermalPolicy::default());
    assert!(machine.observe(&at(50.0), secs(0)).is_some()); // Unknown -> Nominal
    assert_eq!(machine.state(), ThermalState::Nominal);

    // One spike, then back down: nothing happens.
    assert!(machine.observe(&at(86.0), secs(1)).is_none());
    assert!(machine.observe(&at(50.0), secs(2)).is_none());
    assert_eq!(machine.state(), ThermalState::Nominal);
}

#[test]
fn sustained_heat_escalates_after_the_minimum_duration() {
    let policy = ThermalPolicy::default();
    let mut machine = ThermalStateMachine::new(policy);
    machine.observe(&at(50.0), secs(0));

    assert!(machine.observe(&at(86.0), secs(10)).is_none());
    assert!(
        machine
            .observe(&at(86.0), secs(10 + policy.escalation_minimum_seconds - 1))
            .is_none()
    );
    let transition = machine
        .observe(&at(86.0), secs(10 + policy.escalation_minimum_seconds))
        .expect("sustained heat escalates");
    assert_eq!(transition.to, ThermalState::Hot);
    assert_eq!(transition.action, MemoryAction::StopAdmissions);
    assert_eq!(transition.reason, ThermalReason::Escalated);
}

#[test]
fn cooling_needs_both_the_margin_and_the_hold_and_steps_down_once() {
    let policy = ThermalPolicy::default();
    let mut machine = ThermalStateMachine::new(policy);
    machine.observe(&at(50.0), secs(0));
    machine.observe(&at(86.0), secs(10));
    machine.observe(&at(86.0), secs(10 + policy.escalation_minimum_seconds));
    assert_eq!(machine.state(), ThermalState::Hot);

    // A temperature inside the hysteresis margin cannot clear the elevated state regardless of elapsed time.
    let inside = policy.hot_celsius - 1.0;
    assert!(machine.observe(&at(inside), secs(100)).is_none());
    assert!(machine.observe(&at(inside), secs(1_000)).is_none());
    assert_eq!(machine.state(), ThermalState::Hot);

    // Below the margin, but not yet for long enough.
    let outside = policy.hot_celsius - policy.recovery_hysteresis_celsius - 1.0;
    assert!(machine.observe(&at(outside), secs(2_000)).is_none());
    let transition = machine
        .observe(
            &at(outside),
            secs(2_000 + policy.recovery_hysteresis_seconds),
        )
        .expect("sustained cooling de-escalates");
    // One step: Hot -> Warm, not straight to Nominal.
    assert_eq!(transition.from, ThermalState::Hot);
    assert_eq!(transition.to, ThermalState::Warm);
    assert_eq!(transition.reason, ThermalReason::Cooled);
}

#[test]
fn losing_a_sensor_from_nominal_reports_that_evidence_is_gone() {
    let mut machine = ThermalStateMachine::new(ThermalPolicy::default());
    machine.observe(&at(50.0), secs(0));
    assert_eq!(machine.state(), ThermalState::Nominal);

    let lost = machine
        .observe(&ThermalSignals::default(), secs(1))
        .expect("losing every sensor is a state change");
    assert_eq!(lost.to, ThermalState::Unknown);
    assert_eq!(lost.reason, ThermalReason::EvidenceLost);
    assert_eq!(lost.action, MemoryAction::Continue);
    assert_eq!(lost.celsius, None);
}

/// Sensor loss under load must retain an elevated guard state because missing readings do not prove cooling.
#[test]
fn losing_the_sensor_while_hot_does_not_clear_the_guard() {
    let policy = ThermalPolicy::default();
    let mut machine = ThermalStateMachine::new(policy);
    machine.observe(&at(50.0), secs(0));
    machine.observe(&at(86.0), secs(10));
    machine.observe(&at(86.0), secs(10 + policy.escalation_minimum_seconds));
    assert_eq!(machine.state(), ThermalState::Hot);

    assert!(
        machine
            .observe(&ThermalSignals::default(), secs(100))
            .is_none(),
        "a dropped reading must not move an elevated state"
    );
    assert_eq!(machine.state(), ThermalState::Hot);
    assert_eq!(machine.state().action(), MemoryAction::StopAdmissions);
}

/// The first reading after boot or sensor loss must serve the same escalation dwell as other readings.
#[test]
fn the_first_reading_after_blindness_still_serves_the_escalation_minimum() {
    let policy = ThermalPolicy::default();
    let mut machine = ThermalStateMachine::new(policy);

    let first = machine
        .observe(&at(86.0), secs(0))
        .expect("evidence returning is reportable");
    assert_eq!(
        first.to,
        ThermalState::Nominal,
        "a single hot sample must not arm the guard, even from Unknown"
    );
    assert_eq!(first.action, MemoryAction::Continue);

    assert!(machine.observe(&at(86.0), secs(1)).is_none());
    let escalated = machine
        .observe(&at(86.0), secs(1 + policy.escalation_minimum_seconds))
        .expect("sustained heat still escalates");
    assert_eq!(escalated.to, ThermalState::Hot);
}

#[test]
fn defaults_are_conservative_and_ordered() {
    let policy = ThermalPolicy::default();
    assert!(policy.warning_celsius < policy.hot_celsius);
    assert!(policy.hot_celsius < policy.critical_celsius);
    // Slower than the memory ladder's 3 s: a thermal spike must not act.
    assert!(policy.escalation_minimum_seconds >= 15);
    assert!(policy.recovery_hysteresis_celsius > 0.0);
}

/// Heat oscillating across rung boundaries must accumulate dwell and eventually stop admissions or unload (M16).
#[test]
fn oscillating_across_a_rung_boundary_still_escalates() {
    let policy = ThermalPolicy::default();
    let minimum = policy.escalation_minimum_seconds;
    let mut machine = ThermalStateMachine::new(policy);

    // Establish Hot before testing escalation rather than initial-state entry.
    for second in 0..=(minimum + 1) {
        machine.observe(&at(86.0), secs(second));
    }
    assert_eq!(machine.state(), ThermalState::Hot);

    // Alternate across Critical longer than the escalation minimum without consecutive equal samples.
    let start = minimum + 2;
    let mut escalated = false;
    for step in 0..(minimum * 3) {
        let celsius = if step % 2 == 0 { 91.0 } else { 88.0 };
        if machine.observe(&at(celsius), secs(start + step)).is_some() {
            escalated = true;
            break;
        }
    }
    assert!(
        escalated,
        "sustained heat across a rung boundary must escalate"
    );
    assert_eq!(machine.state(), ThermalState::Critical);
}

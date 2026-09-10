use super::*;

const GIB: u64 = 1024 * 1024 * 1024;

fn machine() -> PressureStateMachine {
    PressureStateMachine::new(MemoryPolicy::default())
}

fn sample(available_gib: u64) -> MemorySignals {
    MemorySignals {
        available_bytes: available_gib * GIB,
        total_bytes: 128 * GIB,
        psi_some_avg10: 0.0,
        psi_full_avg10: 0.0,
        available_drop_bytes_per_second: 0,
        kernel_oom_event: false,
        gpu_celsius: None,
        cpu_celsius: None,
    }
}

fn observe(
    m: &mut PressureStateMachine,
    available_gib: u64,
    secs: u64,
) -> Option<PressureTransition> {
    m.observe(
        &sample(available_gib),
        ObservationContext::default(),
        Duration::from_secs(secs),
    )
}

#[test]
fn emergency_does_not_recover_while_the_engine_is_still_active() {
    let mut m = machine();
    let active = || ObservationContext {
        engine_active: true,
        engine_loading: false,
    };
    let stopped = || ObservationContext {
        engine_active: false,
        engine_loading: false,
    };
    // A cliff below the emergency reserve latches Emergency immediately.
    assert!(
        m.observe(&sample(4), active(), Duration::from_secs(0))
            .is_some()
    );
    assert_eq!(m.state(), PressureState::Emergency);
    // An engine still loading is active even before its instance is installed, so recovery cannot begin.
    assert_eq!(
        m.observe(&sample(4), active(), Duration::from_secs(2)),
        None
    );
    assert_eq!(m.state(), PressureState::Emergency);
    // Once the engine is actually gone, recovery is verified after 1 s.
    assert_eq!(
        m.observe(&sample(4), stopped(), Duration::from_secs(4)),
        None
    );
    assert!(
        m.observe(&sample(4), stopped(), Duration::from_secs(6))
            .is_some()
    );
    assert_eq!(m.state(), PressureState::Recovering);
}

#[test]
fn a_worsening_signal_escalates_even_when_the_action_oscillates() {
    let mut m = machine();
    // Oscillation between 12 GiB and 9 GiB must retain escalation dwell instead of resetting at each action change.
    let levels = [12u64, 9, 12, 9, 12, 9, 12, 9];
    let escalated = levels
        .iter()
        .enumerate()
        .any(|(secs, gib)| observe(&mut m, *gib, secs as u64).is_some());
    assert!(
        escalated,
        "a sustained worsening signal must escalate despite oscillating actions"
    );
    assert_ne!(m.state(), PressureState::Normal);
}

#[test]
fn gradual_decline_walks_the_ladder_with_minimum_durations() {
    let mut m = machine();
    // Warning held for 3 s escalates.
    assert_eq!(observe(&mut m, 15, 0), None);
    assert_eq!(observe(&mut m, 15, 2), None);
    let t = observe(&mut m, 15, 3).expect("warning after 3 s");
    assert_eq!(t.to, PressureState::Warning);
    // Draining: classified action is worse than Warning; needs its own 3 s.
    assert_eq!(observe(&mut m, 12, 4), None);
    let t = observe(&mut m, 12, 7).expect("draining after 3 s");
    assert_eq!(t.to, PressureState::Draining);
    // Sustained worse pressure reaches Critical.
    assert_eq!(observe(&mut m, 8, 8), None);
    let t = observe(&mut m, 8, 11).expect("critical after 3 s");
    assert_eq!(t.to, PressureState::Critical);
}

/// A load falling above 9 GiB/s with 108 GB free must ignore velocity while retaining the emergency floor.
#[test]
fn a_loading_engine_is_not_condemned_by_how_fast_memory_falls() {
    let mut ladder = machine();
    let mut loading = sample(100);
    loading.available_drop_bytes_per_second = 12_u64 << 30;
    let context = ObservationContext {
        engine_active: true,
        engine_loading: true,
    };
    assert_eq!(
        ladder.observe(&loading, context, Duration::from_secs(1)),
        None,
        "a load must not be read as an emergency"
    );
    assert_eq!(ladder.state(), PressureState::Normal);

    // After loading, the same velocity inside the warning band must trigger the cliff rule.
    let running = ObservationContext {
        engine_active: true,
        engine_loading: false,
    };
    let mut on_the_ledge = sample(12);
    on_the_ledge.available_drop_bytes_per_second = 12_u64 << 30;
    let transition = ladder
        .observe(&on_the_ledge, running, Duration::from_secs(2))
        .expect("a cliff outside a load is still immediate");
    assert_eq!(transition.to, PressureState::Emergency);

    // A floor breach must remain an emergency during loading.
    let mut fresh = machine();
    let mut starved = sample(4);
    starved.available_drop_bytes_per_second = 0;
    let transition = fresh
        .observe(&starved, context, Duration::from_secs(1))
        .expect("the floor applies while loading");
    assert_eq!(transition.to, PressureState::Emergency);
}

#[test]
fn emergency_is_immediate() {
    let mut m = machine();
    let t = observe(&mut m, 5, 0).expect("emergency on first sample");
    assert_eq!(t.to, PressureState::Emergency);
    assert_eq!(t.reason, PressureReason::ImmediateEmergency);

    let mut m = machine();
    let mut s = sample(60);
    s.kernel_oom_event = true;
    let t = m
        .observe(&s, ObservationContext::default(), Duration::from_secs(0))
        .expect("kernel OOM is immediate");
    assert_eq!(t.to, PressureState::Emergency);
}

#[test]
fn recovery_requires_engine_stop_then_sustained_headroom() {
    let mut m = machine();
    observe(&mut m, 5, 0);
    // Engine still running: stay in Emergency.
    assert_eq!(
        m.observe(
            &sample(60),
            ObservationContext {
                engine_active: true,
                engine_loading: false
            },
            Duration::from_secs(10)
        ),
        None
    );
    assert_eq!(m.state(), PressureState::Emergency);
    // Verify the engine remains stopped for a sample before starting recovery accounting.
    assert_eq!(
        m.observe(
            &sample(60),
            ObservationContext {
                engine_active: false,
                engine_loading: false
            },
            Duration::from_secs(12)
        ),
        None
    );
    let t = m
        .observe(
            &sample(60),
            ObservationContext {
                engine_active: false,
                engine_loading: false,
            },
            Duration::from_secs(14),
        )
        .expect("recovering once stopped");
    assert_eq!(t.to, PressureState::Recovering);
    // Headroom must be sustained for the hysteresis window.
    assert_eq!(
        m.observe(
            &sample(60),
            ObservationContext {
                engine_active: false,
                engine_loading: false
            },
            Duration::from_secs(20)
        ),
        None
    );
    assert_eq!(
        m.observe(
            &sample(60),
            ObservationContext {
                engine_active: false,
                engine_loading: false
            },
            Duration::from_secs(49)
        ),
        None,
        "one second short of the 30 s window"
    );
    let t = m
        .observe(
            &sample(60),
            ObservationContext {
                engine_active: false,
                engine_loading: false,
            },
            Duration::from_secs(50),
        )
        .expect("normal after sustained recovery");
    assert_eq!(t.to, PressureState::Normal);
}

#[test]
fn no_oscillation_at_the_warning_threshold() {
    let mut m = machine();
    // Enter warning once by holding below the threshold.
    assert_eq!(observe(&mut m, 15, 0), None);
    let t = observe(&mut m, 15, 4).expect("warning entered");
    assert_eq!(t.to, PressureState::Warning);
    // Recovery needs the 16 GiB entry threshold plus 4 GiB hysteresis, preventing threshold oscillation.
    let mut transitions = 0;
    for second in 0..120 {
        let available = if second % 2 == 0 { 15 } else { 17 };
        if observe(&mut m, available, second).is_some() {
            transitions += 1;
        }
    }
    assert_eq!(transitions, 0);
    assert_eq!(m.state(), PressureState::Warning);
}

#[test]
fn brief_spike_below_duration_does_not_escalate() {
    let mut m = machine();
    assert_eq!(observe(&mut m, 60, 0), None);
    assert_eq!(observe(&mut m, 12, 1), None);
    assert_eq!(observe(&mut m, 60, 2), None);
    assert_eq!(observe(&mut m, 12, 3), None, "candidate reset by recovery");
    assert_eq!(observe(&mut m, 12, 4), None, "held only 1 s since reset");
    assert_eq!(m.state(), PressureState::Normal);
}

#[test]
fn api_projection_stays_within_contract_enum() {
    for state in [
        PressureState::Normal,
        PressureState::Warning,
        PressureState::Draining,
        PressureState::Critical,
        PressureState::Emergency,
        PressureState::Recovering,
    ] {
        assert!(
            ["normal", "warning", "critical", "emergency"].contains(&state.api_name()),
            "{} projected outside the contract enum",
            state.as_str()
        );
    }
}

/// Once stopped, a below-floor engine must settle in Recovering rather than repeatedly reapplying EmergencyStop (M17).
#[test]
fn a_stopped_engine_below_the_floor_settles_in_recovering() {
    let mut m = machine();
    let active = ObservationContext {
        engine_active: true,
        engine_loading: false,
    };
    let stopped = ObservationContext {
        engine_active: false,
        engine_loading: false,
    };

    assert!(
        m.observe(&sample(4), active, Duration::from_secs(0))
            .is_some()
    );
    assert_eq!(m.state(), PressureState::Emergency);

    // Verify the stopped state for one second before entering Recovering.
    assert_eq!(m.observe(&sample(4), stopped, Duration::from_secs(2)), None);
    assert!(
        m.observe(&sample(4), stopped, Duration::from_secs(4))
            .is_some()
    );
    assert_eq!(m.state(), PressureState::Recovering);

    // Below-floor memory cannot re-escalate while no engine remains to stop.
    for second in 5..120 {
        let transition = m.observe(&sample(4), stopped, Duration::from_secs(second));
        assert!(
            transition.is_none(),
            "a stopped engine must not re-escalate at {second}s: {transition:?}"
        );
        assert_eq!(m.state(), PressureState::Recovering);
    }

    // A new active engine below the floor must restore emergency escalation.
    assert!(
        m.observe(&sample(4), active, Duration::from_secs(120))
            .is_some()
    );
    assert_eq!(m.state(), PressureState::Emergency);
}

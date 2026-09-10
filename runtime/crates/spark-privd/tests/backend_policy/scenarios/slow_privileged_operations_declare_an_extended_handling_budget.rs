/// Declare budgets for slow operations so watchdog restarts cannot interrupt legitimate mutations.
#[test]
fn slow_privileged_operations_declare_an_extended_handling_budget() {
    // Allow nmcli's 90-second wait plus process startup.
    for kind in ["connect_wifi", "configure_travel_ap"] {
        let budget = spark_privd::server::handling_budget(kind)
            .unwrap_or_else(|| panic!("{kind} runs nmcli --wait 90 and needs a budget"));
        assert!(
            budget > Duration::from_secs(90),
            "{kind} budget {budget:?} does not clear its own nmcli wait"
        );
    }
    assert!(
        spark_privd::server::handling_budget("configure_lan_ipv4")
            .is_some_and(|budget| budget > Duration::from_secs(23))
    );

    // Package and image work runs for minutes.
    for kind in [
        "ensure_engine_image",
        "refresh_system_updates",
        "install_system_updates",
    ] {
        let budget = spark_privd::server::handling_budget(kind)
            .unwrap_or_else(|| panic!("{kind} needs a budget"));
        assert!(
            budget >= Duration::from_secs(30 * 60),
            "{kind} budget {budget:?} is too short for package work"
        );
    }

    // A vendor package install plus the sign-in window runs for minutes; a status read must not.
    assert!(
        spark_privd::server::handling_budget("prepare_tailscale")
            .is_some_and(|budget| budget >= Duration::from_secs(10 * 60))
    );
    assert!(spark_privd::server::handling_budget("tailscale_status").is_none());

    // Container pruning walks the whole store.
    assert!(spark_privd::server::handling_budget("prune_container_storage").is_some());

    // Keep short default budgets for ordinary operations so wedged handlers still trigger recovery.
    for kind in [
        "set_hostname",
        "reboot",
        "confirm_network_change",
        "stop_model",
    ] {
        assert!(
            spark_privd::server::handling_budget(kind).is_none(),
            "{kind} must not weaken the watchdog"
        );
    }
}

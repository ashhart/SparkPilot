use super::*;
use std::path::Path;

#[test]
fn production_journal_lives_under_the_privileged_helpers_state_parent() {
    let path = Path::new(NETWORK_ROLLBACK_DIRECTORY);
    assert_eq!(path.parent(), Some(Path::new("/var/lib/spark-privd")));
    assert_ne!(path.parent(), Some(Path::new("/var/lib/spark-runtime")));
}

#[test]
fn rollback_can_delete_internal_setup_profiles_but_not_fabric_or_option_names() {
    for (profile, allowed) in [
        (DIRECT_PROFILE, true),
        (TRAVEL_PROFILE, true),
        ("Home WiFi", true),
        ("SparkPilot-CX7-owner-worker", false),
        ("--ask", false),
        ("", false),
    ] {
        let rollback = NetworkRollback::commands(vec![(
            NMCLI_BIN.into(),
            vec![
                "connection".into(),
                "delete".into(),
                "id".into(),
                profile.into(),
            ],
        )]);
        assert_eq!(valid_network_rollback(&rollback), allowed, "{profile:?}");
    }
    assert!(!valid_ssid(DIRECT_PROFILE));
    assert!(!valid_ssid(TRAVEL_PROFILE));
}

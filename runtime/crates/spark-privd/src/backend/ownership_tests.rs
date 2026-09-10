use super::*;

/// Wi-Fi deletion must reject non-Wi-Fi profiles, reserved profiles and option-shaped identifiers.
#[test]
fn an_ssid_cannot_name_our_own_profiles_or_an_nmcli_option() {
    for refused in [
        DIRECT_PROFILE,
        TRAVEL_PROFILE,
        "SparkPilot-CX7-abc-def",
        "--ask",
        "-x",
        "",
    ] {
        assert!(!valid_ssid(refused), "{refused:?} must be refused");
    }
    for accepted in ["The FairOak", "VM1482701", "a", "guest wifi 5G"] {
        assert!(valid_ssid(accepted), "{accepted:?} must be accepted");
    }
}

/// Prune only runtime-owned containers so adopted and unrelated workloads remain untouched.
#[test]
fn container_cleanup_is_scoped_to_our_own_labels() {
    assert!(SPARK_CONTAINER_LABELS.contains(&"spark.project_id"));
    assert!(SPARK_CONTAINER_LABELS.contains(&"spark.cluster"));
    assert!(
        SPARK_CONTAINER_LABELS
            .iter()
            .all(|label| label.starts_with("spark.")),
        "a filter that is not one of our labels would widen the blast radius"
    );
}

/// Stopping projects requires the complete spark-project-<uuid> identity.
#[test]
fn a_project_container_id_must_be_the_strict_form() {
    assert!(crate::protocol::valid_project_container_id(&format!(
        "spark-project-{}",
        uuid::Uuid::nil()
    )));
    for refused in [
        "spark-project-",
        "spark-project-not-a-uuid",
        "spark-project-evil",
        "postgres",
    ] {
        assert!(
            !crate::protocol::valid_project_container_id(refused),
            "{refused:?} must be refused"
        );
    }
}

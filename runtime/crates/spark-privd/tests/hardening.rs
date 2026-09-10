//! Preserve required hardening directives in the packaged privileged-helper unit.

use spark_privd::backend::DOCKER_CONFIG_DIR;
use std::path::PathBuf;

fn unit_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packaging/systemd/spark-privd.service")
}

const REQUIRED_DIRECTIVES: &[&str] = &[
    "CapabilityBoundingSet=",
    "NoNewPrivileges=yes",
    "PrivateTmp=yes",
    "PrivateDevices=yes",
    "ProtectSystem=strict",
    "ProtectHome=yes",
    "ProtectKernelTunables=yes",
    "ProtectKernelModules=yes",
    "ProtectKernelLogs=yes",
    "ProtectControlGroups=yes",
    "ProtectClock=yes",
    "ProtectHostname=yes",
    "ProtectProc=invisible",
    "RestrictSUIDSGID=yes",
    "RestrictNamespaces=yes",
    "LockPersonality=yes",
    "RestrictRealtime=yes",
    "RemoveIPC=yes",
    "SystemCallArchitectures=native",
    "RestrictAddressFamilies=",
    "UMask=0027",
];

#[test]
fn packaged_unit_keeps_required_hardening() {
    let content = std::fs::read_to_string(unit_path())
        .unwrap_or_else(|error| panic!("reading spark-privd.service: {error}"));
    for directive in REQUIRED_DIRECTIVES {
        assert!(
            content.contains(directive),
            "unit must keep hardening directive `{directive}`"
        );
    }
    // The unit must not grant a shell or an unrestricted environment.
    assert!(!content.contains("ExecStart=/bin/sh"));
    assert!(!content.contains("ExecStart=/bin/bash"));
    assert!(content.contains("\nCapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN\n"));
    assert!(
        content
            .contains("\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_PACKET\n")
    );
}

fn sparkd_unit_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packaging/systemd/sparkd.service")
}

/// The packaged helper must admit sparkd's UID rather than its own root UID.
#[test]
fn the_packaged_helper_admits_the_service_account() {
    let helper = std::fs::read_to_string(unit_path())
        .unwrap_or_else(|error| panic!("reading spark-privd.service: {error}"));
    assert!(
        helper.contains("--allowed-user sparkd"),
        "without --allowed-user the helper admits only its own uid, which is root"
    );
    assert!(
        helper.contains("--socket-group sparkd"),
        "without --socket-group the socket is root:root and sparkd cannot open it"
    );
    // Share the socket with the service group while preserving root ownership.
    assert!(helper.contains("\nGroup=sparkd"), "{helper}");
    assert!(helper.contains("\nUser=root"), "{helper}");

    let sparkd = std::fs::read_to_string(sparkd_unit_path())
        .unwrap_or_else(|error| panic!("reading sparkd.service: {error}"));
    assert!(
        sparkd.contains("User=sparkd"),
        "the client must run as the account the helper admits"
    );
    // Give the shared runtime directory exactly one unit owner so startup order cannot change socket ownership.
    assert!(helper.contains("RuntimeDirectory=spark-runtime"));
    assert!(
        !sparkd.contains("RuntimeDirectory=spark-runtime"),
        "sparkd must not re-declare the helper's runtime directory"
    );
}

#[test]
fn the_network_failsafe_journal_has_a_dedicated_root_owned_state_directory() {
    let helper = std::fs::read_to_string(unit_path())
        .unwrap_or_else(|error| panic!("reading spark-privd.service: {error}"));
    assert!(helper.contains("\nUser=root\n"), "{helper}");
    assert!(
        helper.contains("\nStateDirectory=spark-privd\n"),
        "the journal parent must not share sparkd's service-owned state directory"
    );
    assert!(helper.contains("\nStateDirectoryMode=0700\n"), "{helper}");
    assert!(
        helper.contains("ReadWritePaths=/run/spark-runtime /var/lib/spark-runtime /var/lib/spark-privd /etc/spark-runtime"),
        "ProtectSystem=strict must leave the dedicated journal parent writable"
    );
}

/// Under ProtectHome /root is an empty 0000 directory, so every docker CLI child warned about /root/.docker/config.json.
#[test]
fn the_packaged_helper_points_docker_at_a_config_dir_it_can_read() {
    let helper = std::fs::read_to_string(unit_path())
        .unwrap_or_else(|error| panic!("reading spark-privd.service: {error}"));
    let directive = format!("\nEnvironment=DOCKER_CONFIG={DOCKER_CONFIG_DIR}\n");
    assert!(helper.contains(&directive), "{helper}");
    // The directory must sit inside the helper's own writable state so docker can read or create it.
    assert!(
        DOCKER_CONFIG_DIR.starts_with("/var/lib/spark-privd/"),
        "{DOCKER_CONFIG_DIR} is outside StateDirectory=spark-privd"
    );
    assert!(helper.contains("\nProtectHome=yes\n"), "{helper}");
}

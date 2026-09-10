#[test]
fn resolving_a_missing_network_change_is_a_rejection_not_a_success() {
    let root = tempfile::tempdir().unwrap();
    let backend = DockerBackend::new("docker", false)
        .with_network_rollback_journal_dir(root.path().join("network-rollbacks"));
    let configuration_id = Uuid::new_v4();

    for operation in [
        PrivilegedOperation::ConfirmNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        },
        PrivilegedOperation::RollbackNetworkChange {
            request_id: Uuid::new_v4(),
            configuration_id,
        },
    ] {
        let response = backend.execute(&operation).unwrap();
        assert!(!response.accepted, "missing change was reported as success");
        assert_eq!(response.code, "NETWORK_CHANGE_NOT_PENDING");
        assert_eq!(response.details["resolved"], false);
    }
}

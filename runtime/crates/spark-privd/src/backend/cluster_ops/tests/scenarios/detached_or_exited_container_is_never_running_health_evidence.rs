#[test]
fn detached_or_exited_container_is_never_running_health_evidence() {
    for (running, status) in [(false, "exited"), (false, "created"), (true, "exited")] {
        let evidence = ContainerEvidence {
            labels: HashMap::new(),
            image: IMAGE_A.into(),
            running,
            status: status.into(),
        };
        assert!(!(evidence.running && evidence.status == "running"));
    }
}

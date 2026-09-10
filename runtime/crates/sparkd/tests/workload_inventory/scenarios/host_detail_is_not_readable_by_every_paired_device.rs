#[tokio::test]
async fn host_detail_is_not_readable_by_every_paired_device() {
    // Require administrator-level host diagnostics; developer project diagnostics do not authorize external container images or ports.
    for role in ["observer", "user", "developer"] {
        let harness = harness(role, true);
        *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());
        let (status, body) = send(
            harness.state,
            signed_get(&harness.client, "/api/v1/workloads"),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{role} must be refused");
        assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN");
    }

    for role in ["administrator", "owner"] {
        let harness = harness(role, true);
        *harness.scripted_workloads.lock().unwrap() = Some(a_busy_host());
        let (status, _) = send(
            harness.state,
            signed_get(&harness.client, "/api/v1/workloads"),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{role} must be allowed");
    }
}

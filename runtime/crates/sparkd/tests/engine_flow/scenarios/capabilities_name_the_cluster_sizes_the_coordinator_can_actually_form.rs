/// §35.8: the app must read supported member counts and topologies, never infer them from reachable hosts.
#[tokio::test]
async fn capabilities_name_the_cluster_sizes_the_coordinator_can_actually_form() {
    let (h, addr, key, device_id) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let (status, body) = signed_json(
        &client,
        addr,
        &key,
        &device_id,
        "GET",
        "/api/v1/capabilities",
        None,
    )
    .await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");

    let limits = &body["limits"];
    assert_eq!(
        limits["cluster_maximum_supported_members"],
        sparkd::cluster_coordination::MAXIMUM_SUPPORTED_MEMBERS
    );
    assert_eq!(
        limits["cluster_supported_topologies"],
        serde_json::json!(sparkd::cluster_coordination::SUPPORTED_TOPOLOGIES)
    );
    assert_eq!(
        limits["cluster_validated_member_counts"],
        serde_json::json!(sparkd::cluster_coordination::VALIDATED_MEMBER_COUNTS)
    );
    // Larger sets remain importable for inventory, never formable.
    assert_eq!(
        limits["cluster_inventory_only_above_members"],
        sparkd::cluster_coordination::MAXIMUM_SUPPORTED_MEMBERS
    );
    // The published ceiling is the same constant the transaction validator enforces.
    assert!(
        !sparkd::cluster_coordination::VALIDATED_MEMBER_COUNTS
            .iter()
            .any(|count| *count > sparkd::cluster_coordination::MAXIMUM_SUPPORTED_MEMBERS),
        "a validated count above the supported ceiling would be unformable"
    );
    let _ = &h;
}

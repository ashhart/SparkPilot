use spark_contracts::generated::{BuildWorkerRegistration, CreateClusterRequest};

fn fixture(name: &str) -> &'static str {
    match name {
        "create-cluster" => include_str!("fixtures/create-cluster.json"),
        "register-build-worker" => include_str!("fixtures/register-build-worker.json"),
        _ => panic!("unknown fixture"),
    }
}

#[test]
fn cluster_create_uses_node_ids_not_private_member_facts() {
    let expected: serde_json::Value = serde_json::from_str(fixture("create-cluster")).unwrap();
    let request: CreateClusterRequest = serde_json::from_value(expected.clone()).unwrap();
    let encoded = serde_json::to_value(request).unwrap();

    assert_eq!(encoded, expected);
    assert!(encoded.get("member_node_ids").is_some());
    assert!(encoded.get("members").is_none());
}

#[test]
fn build_worker_registration_is_flat_not_capabilities_wrapped() {
    let expected: serde_json::Value =
        serde_json::from_str(fixture("register-build-worker")).unwrap();
    let request: BuildWorkerRegistration = serde_json::from_value(expected.clone()).unwrap();
    let encoded = serde_json::to_value(request).unwrap();

    assert_eq!(encoded, expected);
    assert_eq!(encoded["architectures"][0], "arm64");
    assert!(encoded.get("capabilities").is_none());
}

#[test]
fn permissive_objects_preserve_unknown_fields() {
    let expected = serde_json::json!({
        "name": "lab",
        "member_node_ids": ["a", "b"],
        "future_option": { "enabled": true },
    });
    let request: CreateClusterRequest = serde_json::from_value(expected.clone()).unwrap();
    let encoded = serde_json::to_value(request).unwrap();

    assert_eq!(encoded, expected);
}

#[test]
fn permissive_objects_preserve_every_json_number_shape() {
    let expected: serde_json::Value = serde_json::from_str(
        r#"{
            "name": "lab",
            "member_node_ids": ["a", "b"],
            "large_signed": -9007199254740993,
            "large_unsigned": 18446744073709551615,
            "ordinary": 42,
            "fraction": 1.25,
            "exponent": 1.5e100
        }"#,
    )
    .unwrap();
    let request: CreateClusterRequest = serde_json::from_value(expected.clone()).unwrap();
    let encoded = serde_json::to_value(request).unwrap();

    assert_eq!(encoded, expected);
}

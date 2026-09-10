use super::*;

#[test]
fn secret_string_zeroizes_and_keeps_its_wire_and_debug_contracts() {
    fn assert_zeroize_on_drop<T: zeroize::ZeroizeOnDrop>() {}
    assert_zeroize_on_drop::<SecretString>();

    let literal = "correct-horse-battery-staple";
    let mut secret = SecretString::new(literal);
    assert_eq!(
        serde_json::to_string(&secret).unwrap(),
        format!("\"{literal}\"")
    );
    assert_eq!(format!("{secret:?}"), "<redacted>");
    assert!(!format!("{secret:?}").contains(literal));

    zeroize::Zeroize::zeroize(&mut secret);
    assert!(secret.expose_secret().is_empty());
    assert_eq!(format!("{secret:?}"), "<redacted>");
}

#[test]
fn request_round_trips_without_shell_variants() {
    let op = PrivilegedOperation::StartModel {
        request_id: Uuid::new_v4(),
        recipe_id: "example/model-32b".into(),
        profile_id: "balanced-16k".into(),
        instance_id: Uuid::new_v4(),
        image_digest: format!("registry.example/vllm@sha256:{}", "a".repeat(64)),
        served_name: "example-32b".into(),
        model_snapshot: "/var/lib/spark-runtime/models/snapshots/example/model-32b/rev".into(),
        host_port: 18_100,
        api_key: SecretString::new("b".repeat(64)),
        gpu_memory_utilisation_milli: 700,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        allow_network_during_inference: false,
        memory_limit_bytes: Some(64 * 1024 * 1024 * 1024),
        kv_cache_memory_bytes: None,
        engine_options: Default::default(),
    };
    let json = serde_json::to_vec(&op).unwrap();
    assert!(json.starts_with(br#"{"operation":"start_model""#));
    let parsed: PrivilegedOperation = serde_json::from_slice(&json).unwrap();
    assert_eq!(parsed, op);
    assert!(!format!("{op:?}").contains(&"b".repeat(64)));
}

#[test]
fn pinned_image_rejects_the_all_zero_digest_sentinel() {
    assert!(!valid_pinned_image(&format!(
        "registry.example/vllm@sha256:{}",
        "0".repeat(64)
    )));
}

#[test]
fn pinned_image_rejects_a_leading_dash_repository() {
    // Reject option-shaped image repositories even when their digest is pinned.
    assert!(!valid_pinned_image(&format!(
        "-e=NVIDIA_VISIBLE_DEVICES=all@sha256:{}",
        "a".repeat(64)
    )));
}

#[test]
fn system_hostname_accepts_one_safe_lowercase_label() {
    for valid in ["spark1", "workshop-spark", "a", &"s".repeat(63)] {
        assert!(
            valid_system_hostname(valid),
            "expected valid hostname: {valid}"
        );
    }
    for invalid in [
        "",
        "Spark1",
        "-spark",
        "spark-",
        "spark.local",
        "spark_1",
        "spark 1",
        "spark;reboot",
        &"s".repeat(64),
    ] {
        assert!(
            !valid_system_hostname(invalid),
            "expected invalid hostname: {invalid}"
        );
    }
}

#[test]
fn manual_lan_ipv4_rejects_routes_that_can_cut_off_management() {
    let address = Ipv4Addr::new(192, 168, 100, 63);
    let dns = [Ipv4Addr::new(1, 1, 1, 1), Ipv4Addr::new(8, 8, 8, 8)];
    assert!(valid_lan_ipv4(
        address,
        24,
        Ipv4Addr::new(192, 168, 100, 1),
        &dns
    ));
    assert!(!valid_lan_ipv4(
        address,
        24,
        Ipv4Addr::new(192, 168, 101, 1),
        &dns
    ));
    assert!(!valid_lan_ipv4(
        address,
        24,
        Ipv4Addr::new(169, 254, 1, 1),
        &dns
    ));
    assert!(!valid_lan_ipv4(
        Ipv4Addr::new(192, 168, 100, 0),
        24,
        Ipv4Addr::new(192, 168, 100, 1),
        &dns
    ));
    assert!(!valid_lan_ipv4(
        address,
        24,
        Ipv4Addr::new(192, 168, 100, 1),
        &[dns[0], dns[0]]
    ));
}

#[test]
fn oversized_declaration_is_rejected_without_buffering() {
    let mut bytes = (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec();
    bytes.extend_from_slice(&[0u8; 8]);
    assert!(matches!(
        parse_request(&bytes),
        Err(ProtocolError::RequestTooLarge)
    ));
}

#[test]
fn length_mismatch_is_rejected() {
    let mut bytes = 4u32.to_be_bytes().to_vec();
    bytes.extend_from_slice(b"{\"operation\":\"reboot\"}");
    let err = parse_request(&bytes).unwrap_err();
    assert!(matches!(err, ProtocolError::InvalidFrame(_)));
}

#[test]
fn unknown_operation_tag_is_rejected() {
    let payload =
        br#"{"operation":"run_shell","request_id":"00000000-0000-0000-0000-000000000000"}"#
            .as_slice();
    let mut bytes = (payload.len() as u32).to_be_bytes().to_vec();
    bytes.extend_from_slice(payload);
    assert!(parse_request(&bytes).is_err());
}

#[test]
fn duplicate_request_ids_are_rejected() {
    let mut tracker = RequestIdTracker::new();
    let id = Uuid::new_v4();
    assert!(tracker.observe(id));
    assert!(!tracker.observe(id), "duplicate id must be rejected");
}

#[test]
fn identifier_validation_accepts_canonical_values() {
    assert!(valid_recipe_id("example/model-32b"));
    assert!(valid_profile_id("balanced-16k"));
    assert!(!valid_profile_id("Balanced-16k"));
    assert!(!valid_profile_id("../escape"));
    assert!(!valid_recipe_id("example/model-32b!"));
}

#[test]
fn distributed_execution_digest_is_member_order_independent_and_input_bound() {
    let build = |local_node_id, peer_node_id, image_digest: &str| {
        cluster_execution_digest(ClusterExecutionDigestInput {
            cluster_id: Uuid::from_u128(1),
            launch_id: Uuid::from_u128(2),
            local_node_id,
            peer_node_id,
            coordinator_node_id: Uuid::from_u128(3),
            recipe_id: "example/model-a",
            profile_id: "balanced",
            recipe_digest: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            image_digest,
            served_name: "example/model-a",
            model_snapshot: "/var/lib/spark-runtime/models/snapshots/example/model-a/rev",
            host_port: 18_102,
            gpu_memory_utilisation_milli: 700,
            max_model_length: 16_384,
            max_sequences: 4,
            max_batched_tokens: 8_192,
            tensor_parallel_size: 2,
        })
    };
    let first = build(
        Uuid::from_u128(3),
        Uuid::from_u128(4),
        "registry.example/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    let reversed = build(
        Uuid::from_u128(4),
        Uuid::from_u128(3),
        "registry.example/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
    let substituted = build(
        Uuid::from_u128(3),
        Uuid::from_u128(4),
        "registry.example/vllm@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    assert_eq!(first, reversed);
    assert_ne!(first, substituted);
}

#[test]
fn retired_public_connector_operations_are_rejected() {
    for operation in [
        "install_cloudflare_tunnel",
        "stop_cloudflare_tunnel",
        "cloudflare_tunnel_status",
    ] {
        let body = serde_json::json!({ "operation": operation, "request_id": Uuid::new_v4() });
        assert!(serde_json::from_value::<PrivilegedOperation>(body).is_err());
    }
}

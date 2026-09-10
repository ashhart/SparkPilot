use super::*;
use crate::update::RecordingRunner;
use std::sync::Arc;

fn network() -> Value {
    json!({"Id": "a".repeat(64), "Options":{}})
}

#[test]
fn firewall_requires_exact_reply_only_policy_and_rejects_extra_rules() {
    let policy = Policy::from_network(&network()).unwrap();
    let evidence = json!({"nftables":policy.entries()});
    assert!(policy.matches(&evidence));
    for (index, field, replacement) in [
        (3, "expr", json!([{"accept":null}])),
        (4, "expr", json!([{"accept":null}])),
        (5, "expr", json!([{"accept":null}])),
        (3, "chain", json!("forward")),
    ] {
        let mut changed = evidence.clone();
        changed["nftables"][index]["rule"][field] = replacement;
        assert!(!policy.matches(&changed));
    }
    let mut changed = evidence.clone();
    changed["nftables"]
        .as_array_mut()
        .unwrap()
        .push(json!({"rule": {"expr":[{"accept":null}]}}));
    assert!(!policy.matches(&changed));
    let mut changed = evidence;
    changed["nftables"][1]["chain"]["prio"] = json!(50);
    assert!(!policy.matches(&changed));
}

#[test]
fn installation_requires_kernel_readback_and_preserves_foreign_rules() {
    let policy = Policy::from_network(&network()).unwrap();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "No such file or directory");
    runner.ok(Some(0), "", "");
    runner.ok(
        Some(0),
        &json!({"nftables":policy.entries()}).to_string(),
        "",
    );
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    ensure(&backend, &network()).unwrap();
    assert_eq!(runner.argv_of(NFT).len(), 3);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), r#"{"nftables":[]}"#, "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    assert!(ensure(&backend, &network()).is_err());
    assert_eq!(runner.argv_of(NFT).len(), 1);
}

#[test]
fn missing_firewall_or_failed_verification_refuses_launch() {
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "Operation not permitted");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner);
    assert!(ensure(&backend, &network()).is_err());
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(1), "", "No such file or directory");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), r#"{"nftables":[]}"#, "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner);
    assert!(ensure(&backend, &network()).is_err());
}

#[test]
fn network_identity_cannot_inject_commands_or_redirect_host_firewall() {
    for id in ["", "abcd", "'; flush ruleset", &"A".repeat(64)] {
        assert!(Policy::from_network(&json!({"Id":id})).is_err());
    }
    let mut n = network();
    n["Options"]["com.docker.network.bridge.name"] = json!("eth0");
    assert!(Policy::from_network(&n).is_err());
}

#[test]
fn startup_stops_owned_legacy_dns_without_deleting_data_and_leaves_foreign_containers() {
    let id = "b".repeat(64);
    let network = json!({"Containers":{id.clone():{"Name":"spark-kokoro"}}});
    let owned = json!([{"HostConfig":{"Dns":[]},"Config":{"Image":crate::kokoro::IMAGE,"Labels":{"spark.service":"kokoro"}}}]);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), &owned.to_string(), "");
    runner.ok(Some(0), "", "");
    runner.ok(Some(0), "", "");
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    migration::stop_legacy(&backend, &network).unwrap();
    assert_eq!(
        runner.argv_of("docker")[1],
        vec!["update", "--restart=no", &id]
    );
    assert_eq!(runner.argv_of("docker")[2], vec!["stop", "--time=20", &id]);
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(
        Some(0),
        r#"[{"HostConfig":{"Dns":[]},"Config":{"Labels":{}}}]"#,
        "",
    );
    let backend = DockerBackend::new("docker", false).with_appliance_command_runner(runner.clone());
    assert!(migration::stop_legacy(&backend, &network).is_err());
    assert_eq!(runner.argv_of("docker").len(), 1);
}

#[test]
fn numeric_kernel_conntrack_evidence_accepts_only_established_replies() {
    let policy = Policy::from_network(&network()).unwrap();
    let mut evidence = json!({"nftables":policy.entries()});
    evidence["nftables"][3]["rule"]["expr"] = json!([
        {"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"br-aaaaaaaaaaaa"}},
        {"match":{"op":"==","left":{"ct":{"key":"direction"}},"right":1}},
        {"match":{"op":"in","left":{"ct":{"key":"state"}},"right":2}},
        {"accept":null}
    ]);
    assert!(policy.matches(&evidence));
    for (index, value) in [(1, 0), (2, 1), (2, 6)] {
        let mut changed = evidence.clone();
        changed["nftables"][3]["rule"]["expr"][index]["match"]["right"] = json!(value);
        assert!(!policy.matches(&changed));
    }
}

#[test]
fn network_forbidden_start_creates_and_revalidates_the_fixed_namespace_before_run() {
    let root = tempfile::tempdir().unwrap();
    let docker = root.path().join("docker");
    let log = root.path().join("docker.log");
    let marker = root.path().join("network-created");
    let script = format!(
        r#"#!/bin/sh
printf '%s\n' "$*" >> '{}'
if [ "$1" = network ] && [ "$2" = inspect ]; then
  if [ ! -f '{}' ]; then
    printf 'Error response from daemon: network %s not found\n' "$3" >&2
    exit 1
  fi
  printf '%s\n' '[{{"Name":"spark-inference-isolated","Id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Driver":"bridge","Scope":"local","Internal":false,"Attachable":false,"Ingress":false,"EnableIPv6":false,"Options":{{"com.docker.network.bridge.enable_ip_masquerade":"false","com.docker.network.bridge.enable_icc":"false","com.docker.network.bridge.host_binding_ipv4":"127.0.0.1"}}}}]'
  exit 0
fi
if [ "$1" = network ] && [ "$2" = create ]; then
  touch '{}'
  printf '%s\n' spark-inference-isolated
  exit 0
fi
if [ "$1" = run ]; then
  printf '%s\n' container-id
  exit 0
fi
exit 64
"#,
        log.display(),
        marker.display(),
        marker.display()
    );
    fs::write(&docker, script).unwrap();
    fs::set_permissions(&docker, fs::Permissions::from_mode(0o755)).unwrap();
    let models = root.path().join("models");
    let snapshot = models
        .join("snapshots")
        .join("example")
        .join("model-32b")
        .join("rev");
    fs::create_dir_all(&snapshot).unwrap();
    let runtime = root.path().join("run");
    let probe = root.path().join("uid-probe");
    fs::write(&probe, b"").unwrap();
    let runner = Arc::new(RecordingRunner::new());
    runner.ok(Some(0), &serde_json::json!({"nftables": [{"table": {"family": "inet", "name": "spi_aaaaaaaaaaaa", "comment": "sparkpilot-inference-v1:br-aaaaaaaaaaaa"}}, {"chain": {"family": "inet", "table": "spi_aaaaaaaaaaaa", "name": "input", "type": "filter", "hook": "input", "prio": -50, "policy": "accept"}}, {"chain": {"family": "inet", "table": "spi_aaaaaaaaaaaa", "name": "forward", "type": "filter", "hook": "forward", "prio": -50, "policy": "accept"}}, {"rule": {"family": "inet", "table": "spi_aaaaaaaaaaaa", "chain": "input", "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "br-aaaaaaaaaaaa"}}, {"match": {"op": "==", "left": {"ct": {"key": "direction"}}, "right": 1}}, {"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": 2}}, {"accept": null}]}}, {"rule": {"family": "inet", "table": "spi_aaaaaaaaaaaa", "chain": "input", "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "br-aaaaaaaaaaaa"}}, {"drop": null}]}}, {"rule": {"family": "inet", "table": "spi_aaaaaaaaaaaa", "chain": "forward", "expr": [{"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "br-aaaaaaaaaaaa"}}, {"drop": null}]}}]}).to_string(), "");
    let backend = DockerBackend::new(docker.to_string_lossy(), false)
        .with_appliance_command_runner(runner)
        .with_paths(&models, &runtime)
        .with_service_uid(std::os::unix::fs::MetadataExt::uid(
            &fs::metadata(&probe).unwrap(),
        ))
        .with_service_gid(std::os::unix::fs::MetadataExt::gid(
            &fs::metadata(&probe).unwrap(),
        ))
        .with_engine_cache_root(root.path().join("engine-cache"));
    let mut operation = start_operation(Uuid::new_v4());
    let PrivilegedOperation::StartModel { model_snapshot, .. } = &mut operation else {
        unreachable!()
    };
    *model_snapshot = snapshot.to_string_lossy().into_owned();

    let response = backend.execute(&operation).expect("isolated model start");

    assert_eq!(response.code, "started");
    let namespace = root.path().join("engine-cache-v2");
    assert_eq!(fs::metadata(&namespace).unwrap().permissions().mode() & 0o777, 0o700);
    let caches = fs::read_dir(&namespace).unwrap().collect::<Result<Vec<_>, _>>().unwrap();
    assert_eq!(caches.len(), 1);
    assert_eq!(fs::metadata(caches[0].path()).unwrap().permissions().mode() & 0o777, 0o770);
    assert!(!root.path().join("engine-cache").exists());
    let calls = fs::read_to_string(&log).unwrap();
    let lines = calls.lines().collect::<Vec<_>>();
    assert_eq!(
        lines[0],
        format!("network inspect {INFERENCE_ISOLATED_NETWORK}")
    );
    assert_eq!(
        lines[1],
        format!(
            "network create --driver=bridge --opt=com.docker.network.bridge.enable_ip_masquerade=false --opt=com.docker.network.bridge.enable_icc=false --opt=com.docker.network.bridge.host_binding_ipv4=127.0.0.1 {INFERENCE_ISOLATED_NETWORK}"
        )
    );
    assert_eq!(
        lines[2],
        format!("network inspect {INFERENCE_ISOLATED_NETWORK}")
    );
    assert!(lines[3].starts_with("run --detach --pull=never"));
    assert!(lines[3].contains("--network=spark-inference-isolated"));
    assert!(lines[3].contains("--publish=127.0.0.1:"));
    assert!(lines[3].contains("--dns=127.0.0.1"));
    assert!(!lines[3].contains("--publish=0.0.0.0:"));
    assert!(!lines[3].contains("--network=bridge"));
}

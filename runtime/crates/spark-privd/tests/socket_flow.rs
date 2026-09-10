//! Verify socket peer authentication, typed operation handling and replay rejection.

use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;

use spark_privd::backend::FakeBackend;
use spark_privd::protocol::{
    ClusterExecutionDigestInput, PrivilegedOperation, PrivilegedResponse, SecretString,
    cluster_execution_digest, read_response, write_request,
};
use spark_privd::server::serve;

fn current_euid() -> u32 {
    unsafe { libc::geteuid() }
}
/// Start a temporary-socket server whose returned handle stops it on drop.
struct ServerHarness {
    path: std::path::PathBuf,
    _dir: tempfile::TempDir,
}

fn spawn_server(backend: FakeBackend, allowed_uid: u32) -> ServerHarness {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&path).unwrap();
    std::thread::spawn(move || {
        let _ = serve(listener, allowed_uid, &backend);
    });
    ServerHarness { path, _dir: dir }
}

fn request(
    op: PrivilegedOperation,
    path: &std::path::Path,
) -> Result<PrivilegedResponse, std::io::Error> {
    let mut stream = UnixStream::connect(path)?;
    write_request(&mut stream, &op).expect("write request");
    Ok(read_response(&mut stream).expect("read response"))
}

#[test]
fn fake_backend_round_trip_over_socket() {
    let harness = spawn_server(FakeBackend::default(), current_euid());

    let probe = request(
        PrivilegedOperation::ProbeContainerRuntime {
            request_id: uuid::Uuid::new_v4(),
        },
        &harness.path,
    )
    .unwrap();
    assert!(probe.accepted);
    assert_eq!(probe.code, "runtime_available");

    let start = request(
        PrivilegedOperation::StartModel {
            request_id: uuid::Uuid::new_v4(),
            recipe_id: "example/model-32b".into(),
            profile_id: "balanced-16k".into(),
            instance_id: uuid::Uuid::new_v4(),
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
            memory_limit_bytes: None,
            kv_cache_memory_bytes: None,
            engine_options: Default::default(),
        },
        &harness.path,
    )
    .unwrap();
    assert!(start.accepted);
    assert_eq!(start.code, "started");
}

#[test]
fn distributed_execution_inputs_round_trip_and_are_revalidated_over_the_socket() {
    let harness = spawn_server(FakeBackend::default(), current_euid());
    let cluster_id = uuid::Uuid::from_u128(1);
    let launch_id = uuid::Uuid::from_u128(2);
    let local_node_id = uuid::Uuid::from_u128(3);
    let peer_node_id = uuid::Uuid::from_u128(4);
    let recipe_id = "example/model-a";
    let profile_id = "balanced";
    let recipe_digest = "c".repeat(64);
    let image_digest = format!("registry.example/vllm@sha256:{}", "a".repeat(64));
    let served_name = "example/model-a";
    let model_snapshot = "/var/lib/spark-runtime/models/snapshots/example/model-a/revision";
    let host_port = 18_100 + (launch_id.as_u128() % 100) as u16;
    let execution_digest = cluster_execution_digest(ClusterExecutionDigestInput {
        cluster_id,
        launch_id,
        local_node_id,
        peer_node_id,
        coordinator_node_id: local_node_id,
        recipe_id,
        profile_id,
        recipe_digest: &recipe_digest,
        image_digest: &image_digest,
        served_name,
        model_snapshot,
        host_port,
        gpu_memory_utilisation_milli: 700,
        max_model_length: 16_384,
        max_sequences: 4,
        max_batched_tokens: 8_192,
        tensor_parallel_size: 2,
    });
    let response = request(
        PrivilegedOperation::StartClusterLaunch {
            request_id: uuid::Uuid::new_v4(),
            cluster_id,
            launch_id,
            local_node_id,
            peer_node_id,
            coordinator_node_id: local_node_id,
            transaction_id: uuid::Uuid::from_u128(7),
            local_address: "172.31.252.1".parse().unwrap(),
            peer_address: "172.31.252.2".parse().unwrap(),
            coordinator_address: "172.31.252.1".parse().unwrap(),
            recipe_id: recipe_id.into(),
            profile_id: profile_id.into(),
            recipe_digest,
            execution_digest,
            image_digest,
            served_name: served_name.into(),
            model_snapshot: model_snapshot.into(),
            host_port,
            gpu_memory_utilisation_milli: 700,
            max_model_length: 16_384,
            max_sequences: 4,
            max_batched_tokens: 8_192,
            tensor_parallel_size: 2,
        },
        &harness.path,
    )
    .unwrap();
    assert!(response.accepted);
    assert_eq!(response.code, "cluster_launch_started");
}

#[test]
fn duplicate_request_id_is_rejected() {
    let harness = spawn_server(FakeBackend::default(), current_euid());
    let id = uuid::Uuid::new_v4();
    let first = request(
        PrivilegedOperation::ProbeContainerRuntime { request_id: id },
        &harness.path,
    )
    .unwrap();
    assert!(first.accepted);

    let second = request(
        PrivilegedOperation::ProbeContainerRuntime { request_id: id },
        &harness.path,
    )
    .unwrap();
    assert!(!second.accepted);
    assert_eq!(second.code, "duplicate_request");
}

#[test]
fn unrecognised_operation_is_rejected_without_effect() {
    let harness = spawn_server(FakeBackend::default(), current_euid());
    // Reject well-framed payloads that are not typed operations before execution.
    let mut stream = UnixStream::connect(&harness.path).unwrap();
    let payload = br#"{"operation":"run_shell","request_id":"00000000-0000-0000-0000-000000000001","command":"id"}"#;
    use std::io::Write;
    stream
        .write_all(&(payload.len() as u32).to_be_bytes())
        .unwrap();
    stream.write_all(payload).unwrap();
    let response = read_response(&mut stream).unwrap();
    assert!(!response.accepted);
    assert_eq!(response.code, "protocol_error");
}

#[test]
fn wrong_uid_connection_is_refused() {
    // Refuse every connection whose peer UID differs from the configured UID.
    let harness = spawn_server(FakeBackend::default(), current_euid().wrapping_add(1));
    let mut stream = UnixStream::connect(&harness.path).expect("socket reachable");
    use std::io::Read;
    // Server closes the connection without a response.
    let mut buf = Vec::new();
    let result = stream.read_to_end(&mut buf);
    assert!(result.is_ok(), "read errors are tolerated");
    assert!(
        buf.is_empty(),
        "wrong-uid peer must receive no privileged response"
    );
    drop(stream);
}

#[test]
fn socket_ownership_contract() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&path).unwrap();
    let meta = std::fs::metadata(&path).unwrap();
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(
        meta.permissions().mode() & 0o777,
        0o660,
        "socket must be 0660"
    );
    drop(listener);

    let parent = std::fs::metadata(dir.path()).unwrap();
    assert_eq!(
        parent.permissions().mode() & 0o777,
        0o750,
        "socket dir must be 0750"
    );
}

#[test]
fn peer_euid_round_trip() {
    let (a, b) = UnixStream::pair().unwrap();
    std::mem::drop(a);
    let uid = spark_privd::server::peer_euid(&b).unwrap();
    assert_eq!(uid, current_euid());
    let _ = b.as_raw_fd();
}

/// Watchdog health must reflect accept-loop state rather than watchdog-thread liveness.
#[test]
fn the_heartbeat_distinguishes_idle_from_wedged() {
    use spark_privd::server::AcceptLoopHeartbeat;
    use std::time::Duration;

    let heartbeat = AcceptLoopHeartbeat::new();
    let budget = Duration::from_millis(50);

    // An idle accept loop remains healthy indefinitely.
    assert!(heartbeat.is_healthy(budget));
    std::thread::sleep(Duration::from_millis(80));
    assert!(
        heartbeat.is_healthy(budget),
        "an idle helper must not be treated as wedged"
    );
}

#[test]
fn a_handler_that_never_returns_stops_the_heartbeat() {
    use spark_privd::server::AcceptLoopHeartbeat;
    use std::time::Duration;

    let heartbeat = AcceptLoopHeartbeat::new();
    let budget = Duration::from_millis(50);

    heartbeat.begin_handling_for_test();
    // Still within budget: a request in flight is normal.
    assert!(heartbeat.is_healthy(budget));

    std::thread::sleep(Duration::from_millis(80));
    assert!(
        !heartbeat.is_healthy(budget),
        "a handler that has exceeded its budget must stop the liveness claim"
    );

    heartbeat.finish_handling_for_test();
    assert!(heartbeat.is_healthy(budget));
}

#[test]
fn a_bounded_collective_keeps_the_watchdog_alive_past_the_default_budget() {
    use spark_privd::server::{AcceptLoopHeartbeat, handling_budget};
    use std::time::Duration;

    let heartbeat = AcceptLoopHeartbeat::new();
    heartbeat.begin_handling_for_test();
    heartbeat.allow_handling_for_test(
        handling_budget("run_cluster_two_rank_test").expect("collective budget"),
    );
    std::thread::sleep(Duration::from_millis(80));
    assert!(
        heartbeat.is_healthy(Duration::from_millis(50)),
        "the operation-specific NCCL bound must override the default watchdog budget"
    );
    heartbeat.finish_handling_for_test();
}

#[test]
fn a_loop_that_has_left_is_never_healthy() {
    use spark_privd::server::AcceptLoopHeartbeat;
    use std::time::Duration;

    let heartbeat = AcceptLoopHeartbeat::new();
    assert!(heartbeat.is_healthy(Duration::from_secs(60)));
    heartbeat.finish_for_test();
    assert!(!heartbeat.is_healthy(Duration::from_secs(60)));
}

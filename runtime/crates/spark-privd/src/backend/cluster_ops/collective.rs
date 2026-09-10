use super::*;

pub(super) fn two_rank_metrics(stdout: &[u8]) -> Option<(u64, u64)> {
    String::from_utf8_lossy(stdout).lines().find_map(|line| {
        let fields = line
            .strip_prefix("SPARK_TWO_RANK_METRICS ")?
            .split_ascii_whitespace()
            .filter_map(|field| field.split_once('='))
            .collect::<HashMap<_, _>>();
        let latency_us = fields.get("latency_us")?.parse().ok()?;
        let bandwidth_mbps = fields.get("bandwidth_mbps")?.parse().ok()?;
        Some((latency_us, bandwidth_mbps))
    })
}

/// Run ray status with the container capability policy and an already-present engine image.
pub(super) fn collective_test_argv(docker_bin: &str, image_digest: &str) -> Vec<String> {
    vec![
        docker_bin.to_owned(),
        "run".into(),
        "--rm".into(),
        // Require a local image so a probe cannot fetch caller-selected code.
        "--pull=never".into(),
        "--network=host".into(),
        "--gpus=all".into(),
        "--read-only".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges:true".into(),
        "--pids-limit=2048".into(),
        "--tmpfs=/tmp:rw,nosuid,nodev,size=256m".into(),
        image_digest.to_owned(),
        "ray".into(),
        "status".into(),
    ]
}

pub(super) fn two_rank_probe_name(
    transaction_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    node_rank: u8,
) -> String {
    format!(
        "spark-cluster-probe-{}-{}-{node_rank}",
        transaction_id.simple(),
        local_node_id.simple(),
    )
}

pub(super) fn two_rank_probe_labels(
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    node_rank: u8,
) -> HashMap<String, String> {
    HashMap::from([
        ("spark.owner".into(), CLUSTER_PROBE_OWNER.into()),
        ("spark.cluster-id".into(), cluster_id.to_string()),
        ("spark.transaction-id".into(), transaction_id.to_string()),
        ("spark.local-node-id".into(), local_node_id.to_string()),
        ("spark.cluster-role".into(), "collective-probe".into()),
        ("spark.node-rank".into(), node_rank.to_string()),
    ])
}

pub(super) struct TwoRankCommand<'a> {
    pub(super) transaction_id: uuid::Uuid,
    pub(super) cluster_id: uuid::Uuid,
    pub(super) local_node_id: uuid::Uuid,
    pub(super) coordinator_address: Ipv4Addr,
    pub(super) node_rank: u8,
    pub(super) image_digest: &'a str,
    pub(super) fabric_interface: &'a str,
}

pub(super) fn two_rank_collective_argv(
    docker_bin: &str,
    command: &TwoRankCommand<'_>,
) -> Vec<String> {
    let port = 24_000
        + u16::from_be_bytes([
            command.cluster_id.as_bytes()[0],
            command.cluster_id.as_bytes()[1],
        ]) % 8_000;
    let name = two_rank_probe_name(
        command.transaction_id,
        command.local_node_id,
        command.node_rank,
    );
    let labels = two_rank_probe_labels(
        command.transaction_id,
        command.cluster_id,
        command.local_node_id,
        command.node_rank,
    );
    let mut argv = vec![
        TIMEOUT_BIN.into(),
        "--signal=TERM".into(),
        format!("--kill-after={TWO_RANK_KILL_AFTER}"),
        TWO_RANK_TIMEOUT.into(),
        docker_bin.to_owned(),
        "run".into(),
        "--rm".into(),
        format!("--name={name}"),
        "--pull=never".into(),
        "--network=host".into(),
        "--ipc=host".into(),
        "--gpus=all".into(),
        // Keep the capability policy; read-only collective execution still needs two-Spark validation because torch/NCCL may write caches.
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges:true".into(),
        "--pids-limit=2048".into(),
    ];
    append_labels(&mut argv, &labels);
    argv.extend([
        "--env=WORLD_SIZE=2".into(),
        format!("--env=RANK={}", command.node_rank),
        format!("--env=MASTER_ADDR={}", command.coordinator_address),
        format!("--env=MASTER_PORT={port}"),
        format!("--env=SPARK_CLUSTER_ID={}", command.cluster_id),
        format!("--env=NCCL_SOCKET_IFNAME={}", command.fabric_interface),
        format!("--env=GLOO_SOCKET_IFNAME={}", command.fabric_interface),
        command.image_digest.to_owned(),
        "python3".into(),
        "-c".into(),
        TWO_RANK_COLLECTIVE_SCRIPT.into(),
    ]);
    argv
}

pub(super) fn cleanup_two_rank_probe(
    backend: &DockerBackend,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    node_rank: u8,
    image_digest: &str,
) -> Result<bool, BackendError> {
    let name = two_rank_probe_name(transaction_id, local_node_id, node_rank);
    let Some(evidence) = inspect_container(backend, &name)? else {
        return Ok(false);
    };
    let labels = two_rank_probe_labels(transaction_id, cluster_id, local_node_id, node_rank);
    require_exact_container(&evidence, &labels, image_digest, "collective probe")?;
    remove_container(backend, &name)?;
    Ok(true)
}

pub(super) fn run_collective(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    image_digest: &str,
) -> Result<PrivilegedResponse, BackendError> {
    if !valid_pinned_image(image_digest) {
        return Err(BackendError::InvalidInput(
            "collective test requires a digest-pinned image".into(),
        ));
    }
    let argv = collective_test_argv(&backend.docker_bin, image_digest);
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "collective test plan approved".into(),
            details: serde_json::json!({ "outcome": "skipped", "argv": argv }),
        });
    }
    let output = backend.run_appliance(&argv[0], argv[1..].to_vec(), None)?;
    let outcome = if output.success() { "passed" } else { "failed" };
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "collective_test".into(),
        message: "cluster collective validation completed".into(),
        details: serde_json::json!({
            "outcome": outcome,
            "image_digest": image_digest,
            "detail": bounded_detail(&output.stderr),
        }),
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn run_two_rank(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    transaction_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    local_address: Ipv4Addr,
    peer_address: Ipv4Addr,
    coordinator_address: Ipv4Addr,
    node_rank: u8,
    image_digest: &str,
) -> Result<PrivilegedResponse, BackendError> {
    if node_rank > 1
        || local_node_id == peer_node_id
        || local_address == peer_address
        || !DockerBackend::cluster_address_allowed(&local_address)
        || !DockerBackend::cluster_address_allowed(&peer_address)
        || !DockerBackend::cluster_address_allowed(&coordinator_address)
        || !valid_pinned_image(image_digest)
    {
        return Err(BackendError::InvalidInput(
            "two-rank collective fields fail cluster policy".into(),
        ));
    }
    let planned_interface = "TRANSACTION_OWNED_CX7";
    let mut command = TwoRankCommand {
        transaction_id,
        cluster_id,
        local_node_id,
        coordinator_address,
        node_rank,
        image_digest,
        fabric_interface: planned_interface,
    };
    let mut argv = two_rank_collective_argv(&backend.docker_bin, &command);
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "two-rank collective plan approved".into(),
            details: serde_json::json!({
                "argv": argv,
                "probe_name": two_rank_probe_name(transaction_id, local_node_id, node_rank),
                "cleanup_requires_exact_ownership": true,
                "timeout_seconds": 180,
            }),
        });
    }

    let qualified = qualify_owned_cluster_link(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        peer_node_id,
        local_address,
        peer_address,
    )?;
    command.fabric_interface = &qualified.interface;
    argv = two_rank_collective_argv(&backend.docker_bin, &command);

    cleanup_two_rank_probe(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        node_rank,
        image_digest,
    )?;
    let started = std::time::Instant::now();
    let output = backend.run_appliance(&argv[0], argv[1..].to_vec(), None)?;
    let operation_elapsed_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    cleanup_two_rank_probe(
        backend,
        transaction_id,
        cluster_id,
        local_node_id,
        node_rank,
        image_digest,
    )?;
    let metrics = two_rank_metrics(&output.stdout);
    let passed = output.success()
        && String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.trim() == "SPARK_TWO_RANK_OK")
        && metrics.is_some_and(|(latency_us, bandwidth_mbps)| {
            latency_us <= MAX_CLUSTER_LATENCY_US && bandwidth_mbps >= MIN_CLUSTER_BANDWIDTH_MBPS
        });
    let (measured_latency_us, measured_bandwidth_mbps) = metrics.unwrap_or_default();
    Ok(PrivilegedResponse {
        request_id,
        accepted: passed,
        code: if passed {
            "two_rank_collective_passed"
        } else {
            "two_rank_collective_failed"
        }
        .into(),
        message: "two-node NCCL all-reduce completed".into(),
        details: serde_json::json!({
            "outcome": if passed { "passed" } else { "failed" },
            "transaction_id": transaction_id,
            "cluster_id": cluster_id,
            "node_rank": node_rank,
            "measured_latency_us": measured_latency_us,
            "measured_bandwidth_mbps": measured_bandwidth_mbps,
            "minimum_bandwidth_mbps": MIN_CLUSTER_BANDWIDTH_MBPS,
            "maximum_latency_us": MAX_CLUSTER_LATENCY_US,
            "operation_elapsed_ms": operation_elapsed_ms,
            "detail": bounded_detail(&output.stderr),
        }),
    })
}

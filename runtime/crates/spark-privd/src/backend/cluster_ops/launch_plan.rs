use super::*;

pub(super) fn execution_resource(execution_digest: &str) -> String {
    format!("spark_execution_{execution_digest}")
}

pub(super) fn cluster_node_resource(node_id: uuid::Uuid) -> String {
    format!("spark_node_{}", node_id.simple())
}

pub(super) fn launch_name(role: &str, cluster_id: uuid::Uuid, launch_id: uuid::Uuid) -> String {
    format!(
        "spark-cluster-{role}-{}-{}",
        cluster_id.simple(),
        launch_id.simple()
    )
}

pub(super) fn launch_names(
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
) -> [(String, &'static str); 3] {
    [
        (launch_name("head", cluster_id, launch_id), "head"),
        (launch_name("worker", cluster_id, launch_id), "worker"),
        (launch_name("engine", cluster_id, launch_id), "engine"),
    ]
}

pub(super) fn launch_labels(spec: &ClusterLaunchSpec<'_>, role: &str) -> HashMap<String, String> {
    HashMap::from([
        ("spark.owner".into(), CLUSTER_OWNER.into()),
        ("spark.cluster-id".into(), spec.cluster_id.to_string()),
        ("spark.launch-id".into(), spec.launch_id.to_string()),
        ("spark.local-node-id".into(), spec.local_node_id.to_string()),
        ("spark.peer-node-id".into(), spec.peer_node_id.to_string()),
        (
            "spark.coordinator-node-id".into(),
            spec.coordinator_node_id.to_string(),
        ),
        ("spark.cluster-role".into(), role.into()),
        ("spark.recipe-id".into(), spec.recipe_id.into()),
        ("spark.profile-id".into(), spec.profile_id.into()),
        ("spark.recipe-digest".into(), spec.recipe_digest.into()),
        (
            "spark.execution-digest".into(),
            spec.execution_digest.into(),
        ),
        ("spark.image-digest".into(), spec.image_digest.into()),
        ("spark.served-name".into(), spec.served_name.into()),
        (
            "spark.model-snapshot".into(),
            spec.model_snapshot_raw.into(),
        ),
        ("spark.host-port".into(), spec.host_port.to_string()),
        (
            "spark.gpu-memory-utilisation-milli".into(),
            spec.gpu_memory_utilisation_milli.to_string(),
        ),
        (
            "spark.max-model-length".into(),
            spec.max_model_length.to_string(),
        ),
        ("spark.max-sequences".into(), spec.max_sequences.to_string()),
        (
            "spark.max-batched-tokens".into(),
            spec.max_batched_tokens.to_string(),
        ),
        (
            "spark.tensor-parallel-size".into(),
            spec.tensor_parallel_size.to_string(),
        ),
    ])
}

pub(super) fn ray_resources(spec: &ClusterLaunchSpec<'_>) -> String {
    serde_json::json!({
        cluster_node_resource(spec.local_node_id): 1,
        execution_resource(spec.execution_digest): 1,
    })
    .to_string()
}

pub(super) fn ray_member_argv(
    docker_bin: &str,
    spec: &ClusterLaunchSpec<'_>,
    fabric_interface: &str,
) -> (String, HashMap<String, String>, Vec<String>) {
    let is_head = spec.is_coordinator();
    let role = if is_head { "head" } else { "worker" };
    let name = launch_name(role, spec.cluster_id, spec.launch_id);
    let labels = launch_labels(spec, role);
    let resources = ray_resources(spec);
    let mut argv = vec![
        docker_bin.into(),
        "run".into(),
        "--detach".into(),
        "--pull=never".into(),
        format!("--name={name}"),
        "--network=host".into(),
        "--ipc=host".into(),
        "--gpus=all".into(),
        "--restart=unless-stopped".into(),
        "--read-only".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges:true".into(),
        "--pids-limit=4096".into(),
        "--ulimit=memlock=-1".into(),
        "--ulimit=stack=67108864".into(),
        "--tmpfs=/tmp:rw,nosuid,nodev,size=8g".into(),
        format!("--volume={}:/model:ro", spec.model_snapshot.display()),
        format!("--env=NCCL_SOCKET_IFNAME={fabric_interface}"),
        format!("--env=GLOO_SOCKET_IFNAME={fabric_interface}"),
    ];
    append_labels(&mut argv, &labels);
    if is_head {
        argv.extend([
            "--entrypoint=ray".into(),
            spec.image_digest.into(),
            "start".into(),
            format!("--resources={resources}"),
            "--head".into(),
            format!("--node-ip-address={}", spec.local_address),
            "--port=6379".into(),
            "--ray-client-server-port=10001".into(),
            "--node-manager-port=10002".into(),
            "--object-manager-port=10003".into(),
            "--min-worker-port=11000".into(),
            "--max-worker-port=11063".into(),
            format!("--dashboard-host={}", spec.local_address),
            "--dashboard-port=8265".into(),
            "--block".into(),
        ]);
    } else {
        argv.extend([
            "--entrypoint=python3".into(),
            spec.image_digest.into(),
            "-c".into(),
            WORKER_WAIT_SCRIPT.into(),
            spec.coordinator_address.to_string(),
            spec.local_address.to_string(),
            resources,
        ]);
    }
    (name, labels, argv)
}

pub(super) fn engine_argv(
    docker_bin: &str,
    spec: &ClusterLaunchSpec<'_>,
    fabric_interface: &str,
) -> (String, HashMap<String, String>, Vec<String>) {
    let name = launch_name("engine", spec.cluster_id, spec.launch_id);
    let labels = launch_labels(spec, "engine");
    let mut argv = vec![
        docker_bin.into(),
        "run".into(),
        "--detach".into(),
        "--pull=never".into(),
        format!("--name={name}"),
        "--network=host".into(),
        "--ipc=host".into(),
        "--gpus=all".into(),
        "--restart=unless-stopped".into(),
        "--read-only".into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges:true".into(),
        "--pids-limit=4096".into(),
        "--ulimit=memlock=-1".into(),
        "--ulimit=stack=67108864".into(),
        "--tmpfs=/tmp:rw,nosuid,nodev,size=8g".into(),
        format!("--volume={}:/model:ro", spec.model_snapshot.display()),
        "--env=RAY_ADDRESS=127.0.0.1:6379".into(),
        format!("--env=NCCL_SOCKET_IFNAME={fabric_interface}"),
        format!("--env=GLOO_SOCKET_IFNAME={fabric_interface}"),
    ];
    append_labels(&mut argv, &labels);
    argv.extend([
        "--entrypoint=vllm".into(),
        spec.image_digest.into(),
        "serve".into(),
        "/model".into(),
        "--served-model-name".into(),
        spec.served_name.into(),
        "--host".into(),
        "127.0.0.1".into(),
        "--port".into(),
        spec.host_port.to_string(),
        "--distributed-executor-backend".into(),
        "ray".into(),
        "--tensor-parallel-size".into(),
        spec.tensor_parallel_size.to_string(),
        "--gpu-memory-utilization".into(),
        format!(
            "{:.3}",
            f64::from(spec.gpu_memory_utilisation_milli) / 1000.0
        ),
        "--max-model-len".into(),
        spec.max_model_length.to_string(),
        "--max-num-seqs".into(),
        spec.max_sequences.to_string(),
        "--max-num-batched-tokens".into(),
        spec.max_batched_tokens.to_string(),
        "--enable-prefix-caching".into(),
    ]);
    (name, labels, argv)
}

pub(super) fn membership_argv(
    container: &str,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    execution_digest: &str,
    attempts: &str,
) -> Vec<String> {
    let mut resources = [
        cluster_node_resource(local_node_id),
        cluster_node_resource(peer_node_id),
    ];
    resources.sort();
    vec![
        "exec".into(),
        container.into(),
        "python3".into(),
        "-c".into(),
        CLUSTER_LIVENESS_SCRIPT.into(),
        attempts.into(),
        resources[0].clone(),
        resources[1].clone(),
        execution_resource(execution_digest),
    ]
}

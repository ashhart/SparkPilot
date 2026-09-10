use super::*;

pub(super) fn start_launch(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    spec: ClusterLaunchSpec<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let planned_interface = "TRANSACTION_OWNED_CX7";
    let mut member_plan = ray_member_argv(&backend.docker_bin, &spec, planned_interface);
    let mut engine_plan = engine_argv(&backend.docker_bin, &spec, planned_interface);
    if backend.plan_only {
        let member_name = member_plan.0.clone();
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "digest-bound distributed launch plan approved".into(),
            details: serde_json::json!({
                "member_argv": member_plan.2,
                "membership_argv": membership_argv(
                    &member_name,
                    spec.local_node_id,
                    spec.peer_node_id,
                    spec.execution_digest,
                    RAY_WAIT_ATTEMPTS,
                ),
                "engine_argv": spec.is_coordinator().then_some(engine_plan.2),
                "execution_digest": spec.execution_digest,
                "tensor_parallel_size": spec.tensor_parallel_size,
                "loopback_port": spec.host_port,
            }),
        });
    }

    let qualified = qualify_owned_cluster_link(
        backend,
        spec.transaction_id,
        spec.cluster_id,
        spec.local_node_id,
        spec.peer_node_id,
        spec.local_address,
        spec.peer_address,
    )?;
    member_plan = ray_member_argv(&backend.docker_bin, &spec, &qualified.interface);
    engine_plan = engine_argv(&backend.docker_bin, &spec, &qualified.interface);
    let (member_name, member_labels, member_argv) = member_plan;
    let (engine_name, engine_labels, engine_command) = engine_plan;

    let member_reused = ensure_container(
        backend,
        &member_name,
        &member_labels,
        spec.image_digest,
        &member_argv,
    )?;
    if !spec.is_coordinator() {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: if member_reused {
                "cluster_launch_reused"
            } else {
                "cluster_launch_started"
            }
            .into(),
            message: "distributed worker is waiting for or joined to its exact coordinator".into(),
            details: serde_json::json!({
                "cluster_id": spec.cluster_id,
                "launch_id": spec.launch_id,
                "container": member_name,
                "execution_digest": spec.execution_digest,
            }),
        });
    }

    let proof_argv = membership_argv(
        &member_name,
        spec.local_node_id,
        spec.peer_node_id,
        spec.execution_digest,
        RAY_WAIT_ATTEMPTS,
    );
    let proof = backend.run_appliance(&backend.docker_bin, proof_argv, None)?;
    if !proof.success()
        || !String::from_utf8_lossy(&proof.stdout)
            .lines()
            .any(|line| line.trim() == "SPARK_CLUSTER_EXPECTED_2")
    {
        return Err(BackendError::Failure(
            "the exact two-node Ray membership and execution digest were not proved".into(),
        ));
    }
    let engine_reused = ensure_container(
        backend,
        &engine_name,
        &engine_labels,
        spec.image_digest,
        &engine_command,
    )?;
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: if member_reused && engine_reused {
            "cluster_launch_reused"
        } else {
            "cluster_launch_started"
        }
        .into(),
        message: "digest-bound distributed vLLM launch started".into(),
        details: serde_json::json!({
            "cluster_id": spec.cluster_id,
            "launch_id": spec.launch_id,
            "member_container": member_name,
            "engine_container": engine_name,
            "execution_digest": spec.execution_digest,
            "loopback_port": spec.host_port,
        }),
    })
}

pub(super) fn required_label<'a>(
    labels: &'a HashMap<String, String>,
    key: &str,
) -> Result<&'a str, BackendError> {
    labels.get(key).map(String::as_str).ok_or_else(|| {
        BackendError::Failure("cluster container ownership labels are incomplete".into())
    })
}

pub(super) fn verify_probe_member(
    evidence: &ContainerEvidence,
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
    role: &str,
) -> Result<(), BackendError> {
    let labels = &evidence.labels;
    if required_label(labels, "spark.owner")? != CLUSTER_OWNER
        || required_label(labels, "spark.cluster-id")? != cluster_id.to_string()
        || required_label(labels, "spark.launch-id")? != launch_id.to_string()
        || required_label(labels, "spark.local-node-id")? != local_node_id.to_string()
        || required_label(labels, "spark.peer-node-id")? != peer_node_id.to_string()
        || required_label(labels, "spark.cluster-role")? != role
        || required_label(labels, "spark.image-digest")? != evidence.image
        || !valid_sha256(required_label(labels, "spark.execution-digest")?)
        || !valid_pinned_image(&evidence.image)
    {
        return Err(BackendError::Failure(
            "cluster liveness name is owned by different immutable inputs".into(),
        ));
    }
    Ok(())
}

pub(super) const EXECUTION_LABEL_KEYS: [&str; 12] = [
    "spark.recipe-id",
    "spark.profile-id",
    "spark.recipe-digest",
    "spark.execution-digest",
    "spark.image-digest",
    "spark.served-name",
    "spark.model-snapshot",
    "spark.host-port",
    "spark.gpu-memory-utilisation-milli",
    "spark.max-model-length",
    "spark.max-sequences",
    "spark.max-batched-tokens",
];

pub(super) fn probe_engine_http(port: u16) -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_secs(2)) else {
        return false;
    };
    if stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .is_err()
        || stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .is_err()
        || stream
            .write_all(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            .is_err()
    {
        return false;
    }
    let mut bytes = [0_u8; 256];
    let Ok(count) = stream.read(&mut bytes) else {
        return false;
    };
    std::str::from_utf8(&bytes[..count]).is_ok_and(|response| {
        response.starts_with("HTTP/1.1 200 ") || response.starts_with("HTTP/1.0 200 ")
    })
}

pub(super) fn unhealthy(
    request_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
    message: &str,
) -> PrivilegedResponse {
    PrivilegedResponse {
        request_id,
        accepted: false,
        code: "cluster_launch_unhealthy".into(),
        message: message.into(),
        details: serde_json::json!({
            "cluster_id": cluster_id,
            "launch_id": launch_id,
        }),
    }
}

pub(super) fn probe_launch(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
    local_node_id: uuid::Uuid,
    peer_node_id: uuid::Uuid,
) -> Result<PrivilegedResponse, BackendError> {
    if local_node_id == peer_node_id {
        return Err(BackendError::InvalidInput(
            "cluster liveness requires two distinct node identities".into(),
        ));
    }
    let names = launch_names(cluster_id, launch_id);
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "cluster launch liveness plan approved".into(),
            details: serde_json::json!({
                "program": backend.docker_bin,
                "containers": names.iter().map(|(name, _)| name).collect::<Vec<_>>(),
                "requires_exact_ray_and_coordinator_engine": true,
                "expected_node_ids": [local_node_id, peer_node_id],
            }),
        });
    }

    let mut local_member: Option<(String, &'static str, ContainerEvidence)> = None;
    for (name, role) in &names[..2] {
        let Some(evidence) = inspect_container(backend, name)? else {
            continue;
        };
        verify_probe_member(
            &evidence,
            cluster_id,
            launch_id,
            local_node_id,
            peer_node_id,
            role,
        )?;
        if local_member.is_some() {
            return Err(BackendError::Failure(
                "both cluster member roles exist on one Spark".into(),
            ));
        }
        local_member = Some((name.clone(), *role, evidence));
    }
    let Some((member_name, role, member)) = local_member else {
        return Ok(unhealthy(
            request_id,
            cluster_id,
            launch_id,
            "no owned local distributed member process exists",
        ));
    };
    if !member.running || member.status != "running" {
        return Ok(unhealthy(
            request_id,
            cluster_id,
            launch_id,
            "the local distributed member process is not running",
        ));
    }
    let execution_digest = required_label(&member.labels, "spark.execution-digest")?;
    let membership = backend.run_appliance(
        &backend.docker_bin,
        membership_argv(
            &member_name,
            local_node_id,
            peer_node_id,
            execution_digest,
            RAY_PROBE_ATTEMPTS,
        ),
        None,
    )?;
    if !membership.success()
        || !String::from_utf8_lossy(&membership.stdout)
            .lines()
            .any(|line| line.trim() == "SPARK_CLUSTER_EXPECTED_2")
    {
        return Ok(unhealthy(
            request_id,
            cluster_id,
            launch_id,
            "the distributed runtime cannot prove two exact live members",
        ));
    }

    let mut engine_healthy = role != "head";
    if role == "head" {
        let (engine_name, _) = &names[2];
        let Some(engine) = inspect_container(backend, engine_name)? else {
            return Ok(unhealthy(
                request_id,
                cluster_id,
                launch_id,
                "the coordinator vLLM engine is absent",
            ));
        };
        verify_probe_member(
            &engine,
            cluster_id,
            launch_id,
            local_node_id,
            peer_node_id,
            "engine",
        )?;
        if required_label(&engine.labels, "spark.coordinator-node-id")? != local_node_id.to_string()
            || EXECUTION_LABEL_KEYS
                .iter()
                .any(|key| member.labels.get(*key) != engine.labels.get(*key))
        {
            return Err(BackendError::Failure(
                "the coordinator engine does not match the Ray execution identity".into(),
            ));
        }
        let port = required_label(&engine.labels, "spark.host-port")?
            .parse::<u16>()
            .map_err(|_| BackendError::Failure("cluster engine port label is invalid".into()))?;
        let expected_port = 18_100 + (launch_id.as_u128() % 100) as u16;
        engine_healthy = engine.running
            && engine.status == "running"
            && port == expected_port
            && probe_engine_http(port);
    }
    if !engine_healthy {
        return Ok(unhealthy(
            request_id,
            cluster_id,
            launch_id,
            "the coordinator vLLM engine is not healthy on loopback",
        ));
    }
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "cluster_launch_healthy".into(),
        message: "the exact Ray members and coordinator vLLM engine are healthy".into(),
        details: serde_json::json!({
            "cluster_id": cluster_id,
            "launch_id": launch_id,
            "container": member_name,
            "execution_digest": execution_digest,
            "expected_node_ids": [local_node_id, peer_node_id],
            "engine_required_here": role == "head",
        }),
    })
}

pub(super) fn verify_stop_owner(
    evidence: &ContainerEvidence,
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
    role: &str,
) -> Result<(), BackendError> {
    if required_label(&evidence.labels, "spark.owner")? != CLUSTER_OWNER
        || required_label(&evidence.labels, "spark.cluster-id")? != cluster_id.to_string()
        || required_label(&evidence.labels, "spark.launch-id")? != launch_id.to_string()
        || required_label(&evidence.labels, "spark.cluster-role")? != role
    {
        return Err(BackendError::Failure(
            "cluster stop refused a foreign container name collision".into(),
        ));
    }
    Ok(())
}

pub(super) fn stop_launch(
    backend: &DockerBackend,
    request_id: uuid::Uuid,
    cluster_id: uuid::Uuid,
    launch_id: uuid::Uuid,
) -> Result<PrivilegedResponse, BackendError> {
    let names = launch_names(cluster_id, launch_id);
    if backend.plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "cluster launch stop plan approved".into(),
            details: serde_json::json!({
                "program": backend.docker_bin,
                "containers": names.iter().map(|(name, _)| name).collect::<Vec<_>>(),
                "inspects_exact_ownership_before_any_delete": true,
            }),
        });
    }
    let mut owned = HashSet::new();
    for (name, role) in &names {
        let Some(evidence) = inspect_container(backend, name)? else {
            continue;
        };
        verify_stop_owner(&evidence, cluster_id, launch_id, role)?;
        owned.insert(name.clone());
    }
    let mut removed = Vec::new();
    for index in [2_usize, 1, 0] {
        let name = &names[index].0;
        if owned.contains(name) {
            remove_container(backend, name)?;
            removed.push(name.clone());
        }
    }
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "cluster_launch_stopped".into(),
        message: "owned distributed launch containers stopped".into(),
        details: serde_json::json!({
            "cluster_id": cluster_id,
            "launch_id": launch_id,
            "removed": removed,
            "already_absent": removed.is_empty(),
        }),
    })
}

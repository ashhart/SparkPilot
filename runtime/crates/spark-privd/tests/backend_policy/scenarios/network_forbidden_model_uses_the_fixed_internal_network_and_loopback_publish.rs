#[test]
fn network_forbidden_model_uses_the_fixed_internal_network_and_loopback_publish() {
    let backend = DockerBackend::new("docker", true)
        .with_service_uid(1234)
        .with_service_gid(5678);
    let operation = start_operation(Uuid::new_v4());
    let plan = backend
        .plan_start_model(&operation)
        .expect("valid start plan");
    let argv = &plan.argv[1..];

    assert!(
        argv.iter()
            .any(|argument| argument == "--network=spark-inference-isolated")
    );
    let expected_host_port = operation_host_port(&operation).to_string();
    assert!(
        argv.iter()
            .any(|argument| argument == &format!("--publish=127.0.0.1:{expected_host_port}:8000"))
    );
    assert!(argv.iter().any(|argument| argument == "--gpus=all"));
    assert!(argv.iter().any(|argument| argument == "--pull=never"));
    assert!(argv.iter().any(|argument| argument == "--ipc=host"));
    assert!(argv.iter().any(|argument| argument == "--read-only"));
    assert!(argv.iter().any(|argument| argument == "--cap-drop=ALL"));
    assert!(
        argv.iter()
            .any(|argument| argument == "--security-opt=no-new-privileges:true")
    );
    // Use the model owner's account and an executable compile cache while keeping /tmp noexec.
    assert!(
        argv.iter().any(|argument| argument == "--user=1234:5678"),
        "the engine runs as the service account: {argv:?}"
    );
    assert!(
        argv.iter()
            .any(|argument| argument.starts_with("--volume=/var/lib/spark-privd/engine-cache-v2/")
                && argument.ends_with(":/engine-cache:rw")),
        "the engine cache is a writable directory that outlives the container: {argv:?}"
    );
    assert!(
        argv.iter()
            .any(|argument| argument == "--tmpfs=/tmp:rw,nosuid,nodev,noexec,size=4g")
    );
    for (variable, value) in [
        ("HOME", "/engine-cache"),
        ("XDG_CACHE_HOME", "/engine-cache"),
        ("HF_HOME", "/engine-cache/huggingface"),
        ("TRITON_CACHE_DIR", "/engine-cache/triton"),
        ("TORCHINDUCTOR_CACHE_DIR", "/engine-cache/inductor"),
        ("VLLM_CACHE_ROOT", "/engine-cache/vllm"),
    ] {
        assert!(
            argv.iter()
                .any(|argument| argument == &format!("--env={variable}={value}")),
            "{variable} must point into the writable cache: {argv:?}"
        );
    }
    assert!(argv.iter().any(|argument| argument
        == "--volume=/var/lib/spark-runtime/models/snapshots/example/model-32b/rev:/model:ro"));
    assert!(
        argv.iter()
            .any(|argument| argument.starts_with("--env-file=/run/spark-runtime/credentials/"))
    );
    assert!(
        argv.windows(2)
            .any(|pair| pair == ["--served-model-name", "example-32b"])
    );
    assert!(
        argv.windows(2)
            .any(|pair| pair == ["--gpu-memory-utilization", "0.700"])
    );
    assert!(
        argv.windows(2)
            .any(|pair| pair == ["--max-model-len", "16384"])
    );
    assert!(argv.windows(2).any(|pair| pair == ["--host", "0.0.0.0"]));
    assert!(argv.windows(2).any(|pair| pair == ["--port", "8000"]));
    // Cap both memory and swap so runaway loads cannot exhaust the host.
    let cap = 48u64 * 1024 * 1024 * 1024;
    assert!(
        argv.iter()
            .any(|argument| argument == &format!("--memory={cap}")),
        "engine container carries the cgroup memory cap"
    );
    assert!(
        argv.iter()
            .any(|argument| argument == &format!("--memory-swap={cap}")),
        "swap cannot evade the memory cap"
    );
    assert_eq!(plan.summary["network_policy"], "egress_isolated");
    assert_eq!(plan.summary["public_publish"], false);
    assert!(!argv.iter().any(|argument| argument == "--privileged"));
    assert!(!argv.iter().any(|argument| argument.contains("--pid=host")));
    assert!(
        !argv
            .iter()
            .any(|argument| argument.contains(&"b".repeat(64)))
    );

    let image = argv
        .iter()
        .find(|argument| argument.contains("nvidia/vllm@sha256:"))
        .expect("pinned image");
    assert_eq!(
        image,
        &format!("nvcr.io/nvidia/vllm@sha256:{}", "a".repeat(64))
    );
    let image_index = argv
        .iter()
        .position(|argument| argument == image)
        .expect("pinned image position");
    assert_eq!(argv[image_index - 1], "--entrypoint=vllm");
    assert_eq!(&argv[image_index + 1..image_index + 3], ["serve", "/model"]);
    assert_eq!(
        argv.iter()
            .filter(|argument| argument.as_str() == "vllm")
            .count(),
        0,
        "the inherited image command must not receive a second `vllm` token"
    );
}

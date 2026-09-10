#[test]
fn digest_substitution_and_non_two_way_parallelism_are_rejected() {
    let backend = DockerBackend::new("/usr/bin/docker", true);
    let mut operation = start_operation(
        "example/model-a",
        "balanced",
        IMAGE_A,
        "/var/lib/spark-runtime/models/snapshots/example/model-a/rev-a",
    );
    if let PrivilegedOperation::StartClusterLaunch {
        image_digest,
        tensor_parallel_size,
        ..
    } = &mut operation
    {
        *image_digest = IMAGE_B.into();
        *tensor_parallel_size = 4;
    }
    assert!(ClusterLaunchSpec::from_operation(&backend, &operation).is_err());
}

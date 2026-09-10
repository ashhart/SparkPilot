#[test]
fn generation_blocks_same_worker_aba_and_expiry_removes_artifacts() {
    let harness = harness();
    let worker = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "Owner",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    let build = submit(&harness, &BuildRequirements::default());
    let first = harness
        .service
        .claim_next(&worker, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    let bytes = b"stale generation";
    let artifact = BuildArtifactEvidence {
        artifact_id: Uuid::new_v4(),
        kind: "xcresult".into(),
        relative_path: "result/old.xcresult".into(),
        sha256: sha256_hex(bytes),
        size_bytes: bytes.len() as u64,
    };
    harness
        .service
        .store_artifact(
            &build,
            &worker,
            &first.lease.claim_token,
            &first.lease.artifact_token,
            &artifact,
            bytes,
        )
        .unwrap();
    let generation_dir = harness
        ._directory
        .path()
        .join("build-work")
        .join("builds")
        .join(build.to_string())
        .join(first.recipe.payload.claim_generation.to_string());
    assert!(generation_dir.exists());
    harness
        .clock
        .advance(time::Duration::seconds(CLAIM_LEASE_SECONDS + 1));
    harness.service.requeue_expired().unwrap();
    assert!(!generation_dir.exists());
    harness
        .service
        .register_worker(
            "Owner",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(worker),
        )
        .unwrap();
    let second = harness
        .service
        .claim_next(&worker, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    assert_eq!(
        second.recipe.payload.claim_generation,
        first.recipe.payload.claim_generation + 1
    );
    assert_eq!(
        harness.service.store_artifact(
            &build,
            &worker,
            &first.lease.claim_token,
            &first.lease.artifact_token,
            &artifact,
            bytes,
        ),
        Err("BUILD_CLAIM_INVALID")
    );

    let current_bytes = b"current generation";
    let current_artifact = BuildArtifactEvidence {
        artifact_id: Uuid::new_v4(),
        kind: "diagnostic".into(),
        relative_path: "diagnostics/current.txt".into(),
        sha256: sha256_hex(current_bytes),
        size_bytes: current_bytes.len() as u64,
    };
    harness
        .service
        .store_artifact(
            &build,
            &worker,
            &second.lease.claim_token,
            &second.lease.artifact_token,
            &current_artifact,
            current_bytes,
        )
        .unwrap();
    let conn = harness.service.projects.db.lock();
    assert!(
        !store::requeue_expired_build(
            &conn,
            &build,
            first.recipe.payload.claim_generation,
            "2099-01-01T00:00:00Z",
        )
        .unwrap()
    );
    assert_eq!(
        store::build_row(&conn, &build).unwrap().unwrap().status,
        "claimed"
    );
    assert_eq!(
        store::build_artifacts(&conn, &build, second.recipe.payload.claim_generation)
            .unwrap()
            .len(),
        1
    );
}

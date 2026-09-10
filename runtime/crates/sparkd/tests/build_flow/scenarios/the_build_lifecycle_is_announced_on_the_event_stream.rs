/// PLAN 60.2: a client watching a build must learn about it from the stream, not by polling the row.
#[test]
fn the_build_lifecycle_is_announced_on_the_event_stream() {
    let harness = harness();
    let mut events = harness.state.events.subscribe();
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
    let claim = harness
        .service
        .claim_next(&worker, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    let bytes = b"typed xcresult evidence";
    let artifact = BuildArtifactEvidence {
        artifact_id: Uuid::new_v4(),
        kind: "xcresult".into(),
        relative_path: "result/App.xcresult".into(),
        sha256: sha256_hex(bytes),
        size_bytes: bytes.len() as u64,
    };
    harness
        .service
        .store_artifact(
            &build,
            &worker,
            &claim.lease.claim_token,
            &claim.lease.artifact_token,
            &artifact,
            bytes,
        )
        .unwrap();
    let key = p256::ecdsa::SigningKey::from_slice(&[3; 32]).unwrap();
    let mut result = signed_result(&key, &claim, &claim.recipe.payload.issued_at);
    result.evidence.artifacts = vec![artifact.clone()];
    let signature: p256::ecdsa::Signature =
        key.sign(&sparkd::build_protocol::canonical_json(&result.evidence).unwrap());
    result.worker_signature = base64url_encode(signature.to_bytes().as_ref());
    harness
        .service
        .record_result(
            &build,
            &worker,
            &claim.lease.claim_token,
            &spki(&key),
            &result,
        )
        .unwrap();

    let mut seen = Vec::new();
    while let Ok(event) = events.try_recv() {
        seen.push(event["type"].as_str().unwrap_or_default().to_owned());
    }
    for expected in [
        "build.worker.online",
        "build.started",
        "build.artifact.ready",
        "build.test.completed",
        "build.completed",
    ] {
        assert!(
            seen.iter().any(|name| name == expected),
            "{expected} has no producer; saw {seen:?}"
        );
    }
}

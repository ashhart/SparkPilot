#[test]
fn expiry_requeues_and_late_result_is_refused() {
    let harness = harness();
    let worker = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "First",
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
    let key = p256::ecdsa::SigningKey::from_slice(&[9; 32]).unwrap();
    let late = signed_result(&key, &first, &first.recipe.payload.issued_at);
    harness
        .clock
        .advance(time::Duration::seconds(CLAIM_LEASE_SECONDS + 1));
    assert_eq!(harness.service.requeue_expired().unwrap(), 1);
    assert_eq!(harness.service.get_build(&build).unwrap().status, "queued");
    assert_eq!(
        harness
            .service
            .record_result(
                &build,
                &worker,
                &first.lease.claim_token,
                &spki(&key),
                &late
            )
            .err(),
        Some("BUILD_CLAIM_INVALID")
    );
    let second = Uuid::new_v4();
    harness
        .service
        .register_worker(
            "Second",
            &harness.owner,
            "18.0",
            "macOS 27",
            &capabilities(1),
            Some(second),
        )
        .unwrap();
    let reclaimed = harness
        .service
        .claim_next(&second, &harness.owner, &Uuid::new_v4())
        .unwrap()
        .unwrap();
    assert_eq!(reclaimed.recipe.payload.build_id, build);
    assert_ne!(reclaimed.recipe_sha256, first.recipe_sha256);
}

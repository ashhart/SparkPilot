#[tokio::test]
async fn challenge_expiry_and_bound_recipient_reject_cross_node_proofs() {
    let source = node().await;
    let destination = node().await;
    let other = node().await;
    let identity = prepare(&source).await;
    let c = challenge(&source, &destination, &identity).await;
    let (s, proof) = source
        .post(
            &format!("{BASE}/router-identity/proof"),
            &json!({"challenge":c,"recipient":destination.trust()}),
            true,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{proof}");
    let apply = format!(
        "{BASE}/router-enrollments/{}/apply",
        c["challenge_id"].as_str().unwrap()
    );
    assert!(other.post(&apply, &proof, true).await.0.is_client_error());
    // Advance only the destination clock while retaining current signed timestamps to isolate challenge expiry from authentication skew.
    let clock = Arc::new(sparkd::clock::ManualUtcClock::new(
        time::OffsetDateTime::now_utc() + time::Duration::seconds(61),
    ));
    let mut expired_state = destination.state.clone();
    expired_state.clock = clock;
    let actor = destination.owner_id;
    let result = sparkd::pool_router_identity::enroll(
        &destination.state.database.as_ref().unwrap().lock(),
        &expired_state,
        actor,
        Uuid::parse_str(c["challenge_id"].as_str().unwrap()).unwrap(),
        serde_json::from_value(proof).unwrap(),
    );
    assert!(result.is_err());
    source.stop().await;
    destination.stop().await;
    other.stop().await;
}

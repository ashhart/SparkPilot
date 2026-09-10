#[tokio::test]
async fn fresh_presence_exact_receipts_and_single_use_possession_are_enforced() {
    let source = node().await;
    let destination = node().await;
    let p = format!("{BASE}/router-identity");
    let (s, _) = source.post(&p, &json!({}), false).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let identity = prepare(&source).await;
    let c = challenge(&source, &destination, &identity).await;
    let value = json!({"challenge":c,"recipient":destination.trust()});
    let key = Uuid::new_v4();
    let (s, _) = source
        .call(
            "POST",
            &format!("{BASE}/router-identity/proof"),
            Some(&value),
            Some(key),
            false,
        )
        .await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let (s, proof) = source
        .call(
            "POST",
            &format!("{BASE}/router-identity/proof"),
            Some(&value),
            Some(key),
            true,
        )
        .await;
    assert_eq!(s, StatusCode::OK, "{proof}");
    let (s, again) = source
        .call(
            "POST",
            &format!("{BASE}/router-identity/proof"),
            Some(&value),
            Some(key),
            false,
        )
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(again, proof);
    let apply = format!(
        "{BASE}/router-enrollments/{}/apply",
        c["challenge_id"].as_str().unwrap()
    );
    let (s, _) = destination.post(&apply, &proof, false).await;
    assert_eq!(s, StatusCode::FORBIDDEN);
    let mut forged = proof.clone();
    forged["possession_signature"] = json!(base64url_encode(&[0; 64]));
    assert!(
        destination
            .post(&apply, &forged, true)
            .await
            .0
            .is_client_error()
    );
    let key = Uuid::new_v4();
    let (s, a) = destination
        .call("POST", &apply, Some(&proof), Some(key), true)
        .await;
    assert_eq!(s, StatusCode::OK, "{a}");
    let (s, b) = destination
        .call("POST", &apply, Some(&proof), Some(key), false)
        .await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(a, b);
    assert!(
        destination
            .post(&apply, &proof, true)
            .await
            .0
            .is_client_error()
    );
    source.stop().await;
    destination.stop().await;
}

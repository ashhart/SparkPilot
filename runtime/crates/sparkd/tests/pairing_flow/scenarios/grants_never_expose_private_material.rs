/// Pairing responses must never carry the device private key or node seed.
#[tokio::test]
async fn grants_never_expose_private_material() {
    let peer = full_peer();
    let (invitation, _installer) = bootstrap_owner_invitation(&peer);
    let (status, claim) = run_claim(&peer, &invitation, &peer, "Test Device", "macos").await;
    assert_eq!(status, StatusCode::CREATED);
    let text = serde_json::to_string(&claim.unwrap()).unwrap();
    assert!(
        !text.contains("authority_seed") && !text.contains("private"),
        "grant response leaked private material: {text}"
    );
}

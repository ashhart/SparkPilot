#[tokio::test]
async fn self_signed_descriptors_and_wrong_destination_anchors_cannot_enroll() {
    let source = node().await;
    let destination = node().await;
    let identity = prepare(&source).await;
    let(s,_)=destination.post(&format!("{BASE}/router-enrollments/challenge"),&json!({"identity":identity,"expected_router_node_id":source.state.identity.node_id(),"expected_router_authority_fingerprint":"a".repeat(64),"display_name":"Router"}),false).await;
    assert!(s.is_client_error());
    let c = challenge(&source, &destination, &identity).await;
    let mut trust = destination.trust();
    trust.authority_fingerprint = "b".repeat(64);
    let (s, v) = source
        .post(
            &format!("{BASE}/router-identity/proof"),
            &json!({"challenge":c,"recipient":trust}),
            true,
        )
        .await;
    assert!(s.is_client_error(), "{v}");
    let mut tampered = c.clone();
    tampered["router_identity"]["principal_id"] = json!(Uuid::new_v4());
    let (s, v) = source
        .post(
            &format!("{BASE}/router-identity/proof"),
            &json!({"challenge":tampered,"recipient":destination.trust()}),
            true,
        )
        .await;
    assert!(s.is_client_error(), "{v}");
    source.stop().await;
    destination.stop().await;
}

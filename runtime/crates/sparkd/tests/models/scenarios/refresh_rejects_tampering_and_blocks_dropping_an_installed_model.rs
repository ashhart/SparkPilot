#[tokio::test]
async fn refresh_rejects_tampering_and_blocks_dropping_an_installed_model() {
    let peer = full_peer(false);
    let mut tampered: Value = serde_json::from_str(&expanded_signed_catalogue_json()).unwrap();
    tampered["signature"]["value"] = json!(base64url_encode(&[0_u8; 64]));
    let (status, error) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({ "candidate_json": serde_json::to_string(&tampered).unwrap() }),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        error.unwrap()["error"]["code"],
        "CATALOGUE_SIGNATURE_INVALID"
    );

    sparkd::store::mark_model_installed(
        &peer.state.database.as_ref().unwrap().lock(),
        "example/model-32b",
        4096,
    )
    .unwrap();
    let (status, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({ "candidate_json": signed_catalogue_without_original_json() }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview:?}");
    assert_eq!(
        preview.unwrap()["blockers"][0]["code"],
        "CATALOGUE_INSTALLED_MODEL_DROPPED"
    );

    peer.state
        .jobs
        .create(
            &peer.state.database.as_ref().unwrap().lock(),
            "model.install",
            peer.device_id,
            Some("example/model-7b"),
            r#"{"model":"example/model-7b"}"#,
        )
        .unwrap();
    let (status, preview) = send(
        &peer,
        Method::POST,
        "/api/v1/catalogue/refresh/preview",
        json!({ "candidate_json": expanded_signed_catalogue_json() }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{preview:?}");
    assert_eq!(
        preview.unwrap()["blockers"][0]["code"],
        "CATALOGUE_INSTALL_IN_PROGRESS"
    );
}

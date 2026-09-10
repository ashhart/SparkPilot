/// Report fit unknown on list/detail when no engine subsystem can observe residency.
#[tokio::test]
async fn fit_is_unknown_when_residency_cannot_be_observed() {
    let peer = peer_without_engine();

    let (status, body) = get(&peer, "/api/v1/models").await;
    assert_eq!(status, StatusCode::OK);
    let body = body.unwrap();
    assert_eq!(body["items"][0]["fit"], "unknown");

    let (status, detail) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(detail.unwrap()["fit"], "unknown");
}

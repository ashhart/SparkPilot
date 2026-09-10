/// Expose stored unsafe status and measured peak consistently with the admission refusal directing the owner to those measurements.
#[tokio::test]
async fn the_model_surface_reports_stored_profile_safety_and_measured_peak() {
    let peer = full_peer(false);
    let model_id = "example/model-32b";
    let profile_id = "balanced-16k";

    {
        let conn = peer.state.database.as_ref().unwrap().lock();
        sparkd::guard::record_profile_peak(
            &conn,
            model_id,
            profile_id,
            55 << 30,
            &fixture_environment(),
        )
        .unwrap();
    }

    let (status, body) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    assert_eq!(status, StatusCode::OK);
    let profile = &body.unwrap()["profiles"][0];
    assert_eq!(profile["id"], profile_id);
    assert_eq!(profile["safe"], true);
    assert_eq!(
        profile["measured_peak_bytes"],
        serde_json::json!(55_u64 << 30),
        "a recorded peak must reach the surface the owner reviews"
    );

    // Show unsafe state on the same model surface referenced by refusal guidance.
    {
        let conn = peer.state.database.as_ref().unwrap().lock();
        sparkd::guard::mark_profile_unsafe(
            &conn,
            model_id,
            profile_id,
            "MEMORY_PRESSURE_EMERGENCY",
        )
        .unwrap();
    }
    let (_, body) = get(&peer, "/api/v1/models/example%2Fmodel-32b").await;
    let profile = &body.unwrap()["profiles"][0];
    assert_eq!(
        profile["safe"], false,
        "the surface still claimed the profile was safe"
    );

    // And the list endpoint must agree with the detail endpoint.
    let (_, list) = get(&peer, "/api/v1/models").await;
    assert_eq!(list.unwrap()["items"][0]["profiles"][0]["safe"], false);
}

#[tokio::test]
async fn the_catalogue_defaults_every_sensitive_category_off() {
    let (state, client, _directory) = test_state("owner");
    let (status, catalogue) = send(
        state,
        signed_request(
            &client,
            Method::GET,
            "/api/v1/diagnostics",
            Vec::new(),
            false,
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{catalogue}");

    let optional = catalogue["optional_categories"].as_array().unwrap();
    assert!(
        !optional.is_empty(),
        "§46.2 requires owner-selectable categories"
    );
    for category in optional {
        assert_eq!(
            category["included_by_default"], false,
            "{} is on by default",
            category["id"]
        );
        assert_ne!(category["sensitivity"], "operational");
    }
    for section in catalogue["sections"].as_array().unwrap() {
        assert_eq!(section["included_by_default"], true);
        assert_eq!(
            section["sensitivity"], "operational",
            "a default section must not carry an owner-identifying class"
        );
    }
    assert!(
        !catalogue["never_exported"].as_array().unwrap().is_empty(),
        "the categories no checkbox can ever include must be named"
    );
}

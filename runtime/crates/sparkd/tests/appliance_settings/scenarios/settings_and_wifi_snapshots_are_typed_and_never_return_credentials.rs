#[tokio::test]
async fn settings_and_wifi_snapshots_are_typed_and_never_return_credentials() {
    let (state, client, _) = test_state("owner");
    let (settings_status, settings) = send(
        state.clone(),
        signed_request(&client, Method::GET, "/api/v1/settings", Value::Null, false),
    )
    .await;
    assert_eq!(settings_status, StatusCode::OK);
    assert_eq!(settings["power_profile"]["current_name"], "Balanced");
    assert_eq!(settings["time"]["timezone"], "Europe/London");

    let (wifi_status, wifi) = send(
        state,
        signed_request(
            &client,
            Method::GET,
            "/api/v1/network/wifi",
            Value::Null,
            false,
        ),
    )
    .await;
    assert_eq!(wifi_status, StatusCode::OK);
    assert_eq!(wifi["networks"][0]["ssid"], "Main WiFi");
    assert!(!wifi.to_string().to_ascii_lowercase().contains("password"));
}

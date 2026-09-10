use super::*;

#[tokio::test]
async fn web_answers_honor_streaming_and_do_not_inject_events_from_model_text() {
    use crate::web_tools::tool_loop::Answer;
    let text = "A line\n\ndata: [DONE]\n\nAnother line";
    for stream in [true, false] {
        let response = completion_response(
            Answer {
                text: text.into(),
                sources: vec![],
                records: vec![],
                truncated: false,
                error_code: None,
            },
            "family-model",
            stream,
            123,
        )
        .unwrap();
        assert_eq!(
            response.headers()[CONTENT_TYPE],
            if stream {
                "text/event-stream"
            } else {
                "application/json"
            }
        );
        let bytes = axum::body::to_bytes(response.into_body(), 65536)
            .await
            .unwrap();
        if stream {
            let body = std::str::from_utf8(&bytes).unwrap();
            let events = body
                .split("\n\n")
                .filter(|event| !event.is_empty())
                .collect::<Vec<_>>();
            assert_eq!(events.len(), 3);
            assert_eq!(events[2], "data: [DONE]");
            let first: Value =
                serde_json::from_str(events[0].strip_prefix("data: ").unwrap()).unwrap();
            let last: Value =
                serde_json::from_str(events[1].strip_prefix("data: ").unwrap()).unwrap();
            assert_eq!(first["object"], "chat.completion.chunk");
            assert_eq!(first["choices"][0]["delta"]["content"], text);
            assert!(first["choices"][0]["finish_reason"].is_null());
            assert_eq!(last["choices"][0]["finish_reason"], "stop");
            assert_eq!(first["id"], last["id"]);
        } else {
            let body: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(body["choices"][0]["message"]["content"], text);
        }
    }
}

#[test]
fn an_ordinary_gateway_request_never_asks_for_the_web_tools() {
    for body in [
        br#"{"model":"m","messages":[]}"#.as_slice(),
        br#"{"model":"m","messages":[],"metadata":{"project":"x"}}"#.as_slice(),
        br#"{"model":"m","messages":[],"metadata":{"spark_web_access":false}}"#.as_slice(),
        br#"{"model":"m","tools":[{"type":"function","function":{"name":"web_search"}}]}"#
            .as_slice(),
        b"not json".as_slice(),
    ] {
        assert!(
            !wants_web_tools(body),
            "{} was read as asking for the web tools",
            String::from_utf8_lossy(body)
        );
    }
}

#[test]
fn only_the_documented_key_asks_for_the_web_tools() {
    assert!(wants_web_tools(
        br#"{"model":"m","metadata":{"spark_web_access":true}}"#
    ));
    assert!(wants_web_tools(
        br#"{"model":"m","metadata":{"spark_web_access":"true"}}"#
    ));
}

#[test]
fn the_gateway_is_refused_under_every_policy_that_does_not_name_it() {
    use crate::web_tools::backend::WebAccessSettings;
    use crate::web_tools::policy::WebAccessPolicy;
    for (policy, harness) in [
        (WebAccessPolicy::Off, false),
        (WebAccessPolicy::Off, true),
        (WebAccessPolicy::AutomationsOnly, false),
        (WebAccessPolicy::AutomationsOnly, true),
        (WebAccessPolicy::AutomationsAndChats, false),
    ] {
        let settings = WebAccessSettings {
            policy,
            harness_access: harness,
            ..WebAccessSettings::default()
        };
        assert!(
            policy::permits(&settings, Surface::Harness).is_err(),
            "the gateway was allowed with policy {} and harness {harness}",
            policy.name()
        );
        assert!(
            policy::permits(&settings, Surface::Automation).is_ok()
                || policy == WebAccessPolicy::Off,
            "automations were refused by a policy that allows them"
        );
    }
    let allowed = WebAccessSettings {
        policy: WebAccessPolicy::AutomationsAndChats,
        harness_access: true,
        ..WebAccessSettings::default()
    };
    assert!(policy::permits(&allowed, Surface::Harness).is_ok());
}

/// A state with a database, so a refusal can be audited the way the runtime audits one.
fn state_with_database() -> AppState {
    let directory = tempfile::tempdir().expect("temp");
    let identity = spark_core::identity::IdentityStore::load_or_create(
        &spark_core::identity::FileIdentityStore::new(directory.path().join("identity")),
        "gateway-test",
    )
    .expect("identity");
    let mut connection = rusqlite::Connection::open_in_memory().expect("db");
    crate::migration::migrate(&mut connection).expect("migrate");
    AppState::new(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().expect("listen"),
            node_name: "gateway-test".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Some(connection),
    )
}

/// BH-42: the web-tools branch skipped `guest::admit` entirely, so the only thing keeping a guest out was the name of a parameter; the refusal is now by role.
#[tokio::test]
async fn a_guest_is_refused_by_role_rather_than_by_the_name_of_a_parameter() {
    let state = state_with_database();
    let principal = Principal {
        device_id: uuid::Uuid::new_v4(),
        role: "guest".to_owned(),
        access_authentication: crate::auth::AccessAuthentication::DeviceSignature,
        user_presence: None,
    };
    let body =
        Bytes::from_static(br#"{"model":"m","messages":[],"metadata":{"spark_web_access":true}}"#);
    let refusal = harness_completion(state, principal, body)
        .await
        .expect_err("a guest must never reach the web tools");
    assert_eq!(refusal.0, StatusCode::FORBIDDEN);
    assert_eq!(
        refusal.1.0["error"]["code"], "ROLE_FORBIDDEN",
        "the refusal must name the role, not the parameter"
    );
}

/// Refused bodies must produce client errors without changing stored application state.
#[tokio::test]
async fn a_refused_body_is_a_client_error_that_changes_no_stored_state() {
    let harness = harness();
    let database = harness.state.database.clone().unwrap();
    let routes = body_routes();
    let mut cases: Vec<(usize, Case)> = Vec::new();
    for (index, (_, _, keys, template)) in routes.iter().enumerate() {
        for case in body_corpus(
            ROUTE_SEED.wrapping_add(index as u64),
            ROUTE_CASES / routes.len(),
            keys,
            template,
        ) {
            cases.push((index, case));
        }
    }
    for case in regressions("api_bodies") {
        cases.push((0, case));
    }

    let mut refused = 0usize;
    for (route, case) in &cases {
        let (method, path, _, _) = routes[*route];
        let before = stored_state(&database, &harness.device_id);
        let (status, body) = send(
            harness.state.clone(),
            signed(&harness, method, path, &case.bytes),
        )
        .await;
        assert!(
            status.as_u16() < 500,
            "{method} {path} answered {status} to {} (seed {ROUTE_SEED:#x})",
            case.label
        );
        if status.is_success() {
            continue;
        }
        refused += 1;
        assert!(
            status.is_client_error(),
            "{method} {path} answered {status} to {}",
            case.label
        );
        // A refusal is a typed envelope, not a stack trace or an echo.
        let envelope: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        let code = envelope["error"]["code"].as_str().unwrap_or_default();
        assert!(
            !code.is_empty(),
            "{method} {path} refused {} without an error code: {}",
            case.label,
            String::from_utf8_lossy(&body[..body.len().min(200)])
        );
        // Exclude rate-limit responses so each corpus case actually exercises its intended parser.
        assert_ne!(
            code, "RATE_LIMITED",
            "{method} {path} rate limited {}, so the body was never parsed",
            case.label
        );
        assert_eq!(
            before,
            stored_state(&database, &harness.device_id),
            "{method} {path} changed stored state while refusing {}",
            case.label
        );
    }
    assert!(
        refused > cases.len() / 2,
        "only {refused} of {} cases were refused; the corpus stopped being hostile",
        cases.len()
    );
}

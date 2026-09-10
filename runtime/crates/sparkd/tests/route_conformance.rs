//! Compare router registrations and generated OpenAPI descriptors in both directions to detect missing routes or undocumented endpoints.

use std::collections::BTreeSet;

/// Read router source at compile time so assertions inspect the built registration source.
const ROUTER_SOURCE: &str = concat!(
    include_str!("../src/route.rs"),
    "\n",
    include_str!("../src/route/protected_routes.rs"),
);

/// Compare parameterized path shapes because local parameter names are not wire semantics.
fn normalise(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    let mut in_parameter = false;
    for character in path.chars() {
        match character {
            '{' => {
                in_parameter = true;
                out.push_str("{}");
            }
            '}' => in_parameter = false,
            _ if in_parameter => {}
            _ => out.push(character),
        }
    }
    out
}

/// Every `(METHOD, path)` the router registers.
fn router_routes() -> BTreeSet<(String, String)> {
    let mut routes = BTreeSet::new();
    let mut rest = ROUTER_SOURCE;
    while let Some(index) = rest.find(".route(") {
        rest = &rest[index + ".route(".len()..];
        // The path literal is the first string after `.route(`.
        let Some(open) = rest.find('"') else { break };
        let Some(close) = rest[open + 1..].find('"') else {
            break;
        };
        let path = &rest[open + 1..open + 1 + close];
        // Limit methods to this balanced route call, regardless of function boundaries or indentation.
        let tail = &rest[open + 2 + close..];
        let mut depth = 1;
        let end = tail
            .char_indices()
            .find_map(|(index, character)| {
                match character {
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    _ => {}
                }
                (depth == 0).then_some(index)
            })
            .expect("route call must close");
        let handlers = &tail[..end];
        for (needle, method) in [
            ("get(", "GET"),
            ("post(", "POST"),
            ("put(", "PUT"),
            ("delete(", "DELETE"),
            ("patch(", "PATCH"),
        ] {
            if handlers.contains(needle) {
                routes.insert((method.to_owned(), normalise(path)));
            }
        }
        rest = tail;
    }
    routes
}

/// Every `(METHOD, path)` the published contract defines.
fn contract_routes() -> BTreeSet<(String, String)> {
    spark_contracts::generated::OPERATIONS
        .iter()
        .map(|operation| {
            (
                operation.method.to_ascii_uppercase(),
                normalise(operation.path),
            )
        })
        .collect()
}

#[test]
fn the_router_registers_every_documented_operation() {
    let missing: Vec<_> = contract_routes()
        .difference(&router_routes())
        .cloned()
        .collect();
    assert!(
        missing.is_empty(),
        "the contract documents operations the runtime does not serve, so a \
         client written against the document gets 404s: {missing:?}"
    );
}

#[test]
fn every_served_route_is_documented() {
    let router = router_routes();
    let undocumented: Vec<_> = router.difference(&contract_routes()).cloned().collect();
    assert!(
        undocumented.is_empty(),
        "the runtime serves operations the contract does not describe, so no \
         generated client can reach them: {undocumented:?}"
    );
}

#[test]
fn the_route_scraper_actually_finds_routes() {
    // Require nonempty parsed routes so a broken parser cannot make bidirectional checks pass vacuously.
    let router = router_routes();
    assert!(
        router.len() > 30,
        "expected the full route table, found {}: {router:?}",
        router.len()
    );
    assert!(router.contains(&("GET".to_owned(), "/api/v1/health".to_owned())));
    assert!(router.contains(&("POST".to_owned(), "/api/v1/projects".to_owned())));
    assert!(router.contains(&("GET".to_owned(), "/api/v1/projects".to_owned())));
    assert!(router.contains(&(
        "DELETE".to_owned(),
        "/api/v1/projects/{}/terminals/{}".to_owned()
    )));
}

#[test]
fn bounded_cluster_phases_are_not_abandoned_by_the_general_http_timeout() {
    let source = include_str!("../src/route.rs");
    let cluster = source
        .find("let cluster_operations = Router::new()")
        .expect("cluster operations router must exist");
    let bounded = source
        .find("let bounded = Router::new()")
        .expect("general timeout router must exist");
    let merge = source
        .find(".merge(cluster_operations)")
        .expect("cluster operations must be mounted");
    assert!(
        cluster < bounded && bounded < merge,
        "cluster phases must be authenticated separately and merged after the general timeout layer"
    );
    let cluster_slice = &source[cluster..bounded];
    for path in [
        "/api/v1/cluster/transactions/prepare",
        "/api/v1/cluster/transactions/collective",
        "/api/v1/cluster/launches",
    ] {
        assert!(
            cluster_slice.contains(path),
            "long-running cluster route {path} escaped the timeout-free authenticated router"
        );
    }
}

#[tokio::test]
async fn every_response_carries_the_api_version_header() {
    // Require API-version headers on public success, authentication refusal and 404 responses.
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    let directory = tempfile::tempdir().unwrap();
    let identity = spark_core::identity::IdentityStore::load_or_create(
        &spark_core::identity::FileIdentityStore::new(directory.path().join("identity")),
        "conformance-node",
    )
    .unwrap();
    let mut connection = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut connection).unwrap();
    let state = sparkd::state::AppState::new(
        sparkd::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".to_owned(),
            listen: "127.0.0.1:0".parse().unwrap(),
            node_name: "conformance-node".to_owned(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        std::sync::Arc::new(spark_telemetry::FakeSystemMonitor),
        None,
    )
    .with_database(std::sync::Arc::new(parking_lot::Mutex::new(connection)));

    for (path, expected) in [
        ("/api/v1/health", StatusCode::OK),
        // Protected without a signature: rejected by the auth layer.
        ("/api/v1/status", StatusCode::UNAUTHORIZED),
        ("/api/v1/no-such-route", StatusCode::NOT_FOUND),
    ] {
        let response = sparkd::route::router(state.clone())
            .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), expected, "{path}");
        assert_eq!(
            response
                .headers()
                .get(sparkd::route::API_VERSION_HEADER)
                .and_then(|value| value.to_str().ok()),
            Some(sparkd::route::API_MAJOR_VERSION),
            "{path} must carry the API version header"
        );
    }
}

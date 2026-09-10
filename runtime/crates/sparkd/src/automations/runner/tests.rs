use super::*;
use crate::web_tools::backend::SearchBackend;
use crate::web_tools::session::ToolCallRecord;

fn record(tool: &str, outcome: &str) -> ToolCallRecord {
    ToolCallRecord {
        index: 0,
        tool: tool.to_owned(),
        query: Some("uk news".to_owned()),
        url: (tool == "web_fetch").then(|| "https://news.example/one".to_owned()),
        outcome: outcome.to_owned(),
        error_code: None,
        result_bytes: Some(41),
        duration_ms: 12,
    }
}

#[test]
fn a_guests_web_call_is_audited_as_the_guest_and_not_as_the_owner() {
    let device = uuid::Uuid::from_u128(7);
    let actor = WebActor {
        device_id: Some(device),
        role: "guest".to_owned(),
    };
    let entry = audit_entry(
        &record("web_fetch", "succeeded"),
        Surface::Harness,
        true,
        &actor,
        None,
    );
    assert_eq!(entry.actor_device_id, Some(device));
    assert_eq!(entry.actor_role, "guest");
    assert_eq!(entry.action, "web.fetch.performed");
    assert_eq!(entry.result, "accepted");
}

#[test]
fn a_scheduled_run_is_the_owners_standing_instruction_with_no_device() {
    let entry = audit_entry(
        &record("web_search", "succeeded"),
        Surface::Automation,
        true,
        &WebActor::schedule(),
        Some("html.duckduckgo.com"),
    );
    assert_eq!(entry.actor_device_id, None);
    assert_eq!(entry.actor_role, "owner");
    assert_eq!(entry.action, "web.search.performed");
    // The owner must be able to tell which search service saw the query.
    assert_eq!(entry.details["backend_host"], "html.duckduckgo.com");
}

#[test]
fn the_backend_host_is_named_for_every_configured_search_service() {
    let mut settings = crate::web_tools::backend::WebAccessSettings {
        backend: SearchBackend::DuckDuckGo,
        ..Default::default()
    };
    assert_eq!(
        crate::web_tools::backend::backend_host(&settings).as_deref(),
        Some("html.duckduckgo.com")
    );
    settings.backend = SearchBackend::Brave;
    assert_eq!(
        crate::web_tools::backend::backend_host(&settings).as_deref(),
        Some("api.search.brave.com")
    );
    settings.backend = SearchBackend::Searxng;
    settings.searxng_url = Some("http://127.0.0.1:18119".to_owned());
    assert_eq!(
        crate::web_tools::backend::backend_host(&settings).as_deref(),
        Some("127.0.0.1")
    );
    settings.backend = SearchBackend::Disabled;
    assert_eq!(crate::web_tools::backend::backend_host(&settings), None);
}

#[test]
fn the_hourly_allowance_is_what_is_left_of_the_ceiling() {
    assert_eq!(remaining_hourly_allowance(0), MAX_CALLS_PER_HOUR);
    assert_eq!(remaining_hourly_allowance(1), MAX_CALLS_PER_HOUR - 1);
    assert_eq!(remaining_hourly_allowance(MAX_CALLS_PER_HOUR), 0);
    // An automation on a one-minute schedule must not be able to spend past the hour's ceiling.
    assert_eq!(remaining_hourly_allowance(MAX_CALLS_PER_HOUR + 40), 0);
}

/// BH-40 and BH-36: the robots check and the removal of personal context are audited as themselves.
#[test]
fn a_robots_check_and_a_stripped_context_are_not_audited_as_refused_fetches() {
    let robots = audit_entry(
        &record("web_fetch", "robots_checked"),
        Surface::Automation,
        true,
        &WebActor::schedule(),
        None,
    );
    assert_eq!(robots.action, "web.robots.checked");
    assert_eq!(robots.result, "accepted");
    let stripped = audit_entry(
        &record("personal_context", "stripped"),
        Surface::Chat,
        true,
        &WebActor::schedule(),
        None,
    );
    assert_eq!(stripped.action, "web.personal_context.stripped");
    assert_eq!(stripped.result, "accepted");
}

/// An in-memory Spark with the schema applied, so the durable ledger can be exercised as it runs.
fn ledger_state() -> (AppState, tempfile::TempDir) {
    use spark_core::identity::{FileIdentityStore, IdentityStore};
    let directory = tempfile::tempdir().expect("a directory");
    let identity = FileIdentityStore::new(directory.path().join("identity"))
        .load_or_create("web-ledger")
        .expect("an identity");
    let mut connection = rusqlite::Connection::open_in_memory().expect("a database");
    crate::migration::migrate(&mut connection).expect("the schema");
    let state = AppState::new(
        crate::state::RuntimeConfig {
            api_major: 1,
            runtime_version: "0.1.0".into(),
            listen: "127.0.0.1:0".parse().expect("an address"),
            node_name: "web-ledger".into(),
            data_dir: directory.path().to_path_buf(),
            advertise: false,
            tls: false,
        },
        identity,
        Arc::new(spark_telemetry::FakeSystemMonitor),
        Some(connection),
    );
    (state, directory)
}

fn ledger(state: &AppState) -> DatabaseLedger {
    DatabaseLedger {
        state: state.clone(),
        surface: Surface::Automation,
        permitted: true,
        actor: WebActor::schedule(),
        backend_host: None,
    }
}

/// BH-01: the ceiling is held in the database, so a second run reads what the first already spent.
#[test]
fn the_rolling_hour_is_reserved_durably_and_rolls_forward() {
    let (state, _directory) = ledger_state();
    let first = ledger(&state);
    let second = ledger(&state);
    let now = 1_780_000_000;
    assert!(first.reserve(3, now));
    assert!(second.reserve(3, now));
    assert!(first.reserve(3, now));
    assert!(
        !second.reserve(3, now),
        "a fourth call was allowed against a ceiling of three"
    );
    assert!(
        second.reserve(3, now + HOUR_SECONDS + 1),
        "the hour never rolled forward"
    );
}

#[test]
fn outbound_web_requests_fail_closed_without_durable_storage() {
    let (mut state, _directory) = ledger_state();
    state.database = None;
    assert!(!ledger(&state).reserve(60, 1_780_000_000));
    assert_eq!(
        remaining_hourly_allowance(calls_in_the_last_hour(&state)),
        0
    );
}

/// BH-41: the audit row is written when the call ends, not when the run does.
#[test]
fn a_call_is_audited_the_moment_it_ends() {
    let (state, _directory) = ledger_state();
    ledger(&state).append(&record("web_fetch", "succeeded"));
    let (action, resource, result): (String, String, String) = state
        .database
        .as_ref()
        .expect("a database")
        .lock()
        .query_row(
            "SELECT action, resource, result FROM audit_records",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .expect("one audit row");
    assert_eq!(action, "web.fetch.performed");
    assert_eq!(resource, "https://news.example/one");
    assert_eq!(result, "accepted");
}

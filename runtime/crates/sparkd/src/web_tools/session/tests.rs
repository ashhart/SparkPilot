use super::*;
use crate::clock::ManualUtcClock;
use crate::web_tools::backend::SearchBackend;
use crate::web_tools::guard::ResolveFailed;
use parking_lot::Mutex;
use std::net::IpAddr;

/// Answers every lookup with one public address unless a host is listed as private.
struct Resolver;

impl HostResolver for Resolver {
    fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, ResolveFailed> {
        match host {
            "unknown.example" => Err(ResolveFailed),
            "router.example" => Ok(vec!["192.168.1.1".parse().expect("address")]),
            _ => Ok(vec!["93.184.216.34".parse().expect("address")]),
        }
    }
}

#[derive(Default)]
struct Fake {
    answers: Mutex<HashMap<String, TransportResponse>>,
    asked: Mutex<Vec<TransportRequest>>,
    clock: Option<Arc<ManualUtcClock>>,
    seconds_per_request: i64,
}

impl Fake {
    fn answering(pairs: &[(&str, TransportResponse)]) -> Arc<Self> {
        let fake = Self::default();
        for (url, response) in pairs {
            fake.answers
                .lock()
                .insert((*url).to_owned(), response.clone());
        }
        Arc::new(fake)
    }

    fn slow(
        pairs: &[(&str, TransportResponse)],
        clock: Arc<ManualUtcClock>,
        seconds: i64,
    ) -> Arc<Self> {
        let fake = Arc::try_unwrap(Self::answering(pairs))
            .ok()
            .expect("sole owner");
        Arc::new(Self {
            answers: Mutex::new(fake.answers.into_inner()),
            asked: Mutex::new(Vec::new()),
            clock: Some(clock),
            seconds_per_request: seconds,
        })
    }

    fn asked_urls(&self) -> Vec<String> {
        self.asked
            .lock()
            .iter()
            .map(|item| item.url.clone())
            .collect()
    }
}

#[async_trait::async_trait]
impl WebTransport for Fake {
    async fn get(&self, request: &TransportRequest) -> Result<TransportResponse, String> {
        self.asked.lock().push(request.clone());
        if let Some(clock) = &self.clock {
            clock.advance(time::Duration::seconds(self.seconds_per_request));
        }
        self.answers
            .lock()
            .get(&request.url)
            .cloned()
            .ok_or_else(|| "no answer".to_owned())
    }
}

fn ok(body: &str, content_type: &str) -> TransportResponse {
    TransportResponse {
        status: 200,
        location: None,
        content_type: content_type.to_owned(),
        body: body.to_owned(),
        bytes: body.len(),
    }
}

fn redirect(to: &str) -> TransportResponse {
    TransportResponse {
        status: 302,
        location: Some(to.to_owned()),
        content_type: "text/html".to_owned(),
        body: String::new(),
        bytes: 0,
    }
}

/// The names this Spark answers to, kept out of every outbound question.
fn names() -> crate::web_tools::outbound::OwnNames {
    crate::web_tools::outbound::OwnNames {
        node_id: "6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31".to_owned(),
        hostname: "spark-01".to_owned(),
    }
}

fn clock() -> Arc<ManualUtcClock> {
    Arc::new(ManualUtcClock::new(
        time::OffsetDateTime::from_unix_timestamp(1_780_000_000).expect("in range"),
    ))
}

/// The keyless public backend, so one fixed search URL stands for every session test.
fn keyless() -> WebAccessSettings {
    WebAccessSettings {
        backend: SearchBackend::DuckDuckGo,
        policy: crate::web_tools::policy::WebAccessPolicy::AutomationsAndChats,
        ..WebAccessSettings::default()
    }
}

/// The row for the page itself, past the robots check every fetch of a new host records first.
fn page_row(session: &Session) -> &ToolCallRecord {
    session
        .records()
        .iter()
        .find(|record| record.tool == "web_fetch" && record.outcome != "robots_checked")
        .expect("a page row")
}

fn session(transport: Arc<dyn WebTransport>, clock: Arc<ManualUtcClock>) -> Session {
    Session::new(
        keyless(),
        Surface::Automation,
        None,
        names(),
        Arc::new(Resolver),
        transport,
        clock,
    )
}

const SEARCH_URL: &str = "https://html.duckduckgo.com/html/?q=uk+news&kl=wt-wt";

fn search_answer() -> TransportResponse {
    ok(
        r#"<a class="result__a" href="https://news.example/one">Story one</a>
           <a class="result__snippet" href="https://news.example/one">A summary.</a>"#,
        "text/html",
    )
}

#[tokio::test]
async fn a_search_is_recorded_with_the_exact_text_that_left_the_spark() {
    let fake = Fake::answering(&[(SEARCH_URL, search_answer())]);
    let mut session = session(fake.clone(), clock());
    let answer = session.search("uk news").await;
    assert!(answer.contains("https://news.example/one"), "{answer}");
    assert!(answer.contains("untrusted"), "{answer}");
    let record = &session.records()[0];
    assert_eq!(record.tool, "web_search");
    assert_eq!(record.query.as_deref(), Some("uk news"));
    assert_eq!(record.outcome, "succeeded");
    assert_eq!(record.url, None);
    assert_eq!(fake.asked_urls(), vec![SEARCH_URL.to_owned()]);
}

#[tokio::test]
async fn a_page_is_read_and_becomes_a_source_the_owner_can_see() {
    let fake = Fake::answering(&[
        ("https://news.example/robots.txt", ok("", "text/plain")),
        (
            "https://news.example/one",
            ok("<title>Story one</title><p>Body text.</p>", "text/html"),
        ),
    ]);
    let mut session = session(fake, clock());
    let answer = session.fetch("https://news.example/one").await;
    assert!(answer.contains("Body text."), "{answer}");
    assert!(answer.contains("<untrusted-page-content>"), "{answer}");
    assert_eq!(session.sources().len(), 1);
    assert_eq!(session.sources()[0].url, "https://news.example/one");
    assert_eq!(session.sources()[0].title.as_deref(), Some("Story one"));
    let record = page_row(&session);
    assert_eq!(record.tool, "web_fetch");
    assert_eq!(record.outcome, "succeeded");
    assert_eq!(record.url.as_deref(), Some("https://news.example/one"));
    assert_eq!(record.result_bytes, Some(41));
}

#[tokio::test]
async fn a_blocked_address_is_refused_and_the_refusal_is_shown_to_the_owner() {
    let fake = Fake::answering(&[]);
    let mut session = session(fake.clone(), clock());
    for (url, code) in [
        ("https://127.0.0.1:18100/v1/models", "WEB_FETCH_URL_INVALID"),
        ("http://news.example/plain", "WEB_FETCH_SCHEME_BLOCKED"),
        (
            "https://169.254.169.254/latest/meta-data",
            "WEB_FETCH_PRIVATE_ADDRESS",
        ),
        ("https://router.example/admin", "WEB_FETCH_PRIVATE_ADDRESS"),
        ("file:///etc/passwd", "WEB_FETCH_SCHEME_BLOCKED"),
        ("https://unknown.example/", "WEB_FETCH_HOST_UNRESOLVABLE"),
    ] {
        let answer = session.fetch(url).await;
        assert!(answer.contains(code), "{url} answered {answer}");
    }
    assert!(fake.asked_urls().is_empty(), "nothing may be requested");
    assert!(
        session
            .records()
            .iter()
            .all(|call| call.outcome == "refused")
    );
    assert_eq!(session.records().len(), 6);
}

#[tokio::test]
async fn a_redirect_into_blocked_space_is_refused_at_the_hop() {
    let fake = Fake::answering(&[
        ("https://news.example/robots.txt", ok("", "text/plain")),
        (
            "https://news.example/go",
            redirect("https://169.254.169.254/latest/meta-data"),
        ),
    ]);
    let mut session = session(fake, clock());
    let answer = session.fetch("https://news.example/go").await;
    assert!(answer.contains("WEB_FETCH_PRIVATE_ADDRESS"), "{answer}");
    assert_eq!(page_row(&session).outcome, "refused");
}

#[tokio::test]
async fn a_redirect_chain_that_never_ends_stops_at_the_hop_limit() {
    let fake = Fake::answering(&[
        ("https://news.example/robots.txt", ok("", "text/plain")),
        (
            "https://news.example/loop",
            redirect("https://news.example/loop"),
        ),
    ]);
    let mut session = session(fake.clone(), clock());
    let answer = session.fetch("https://news.example/loop").await;
    assert!(answer.contains("WEB_FETCH_TOO_MANY_REDIRECTS"), "{answer}");
    let hops = fake
        .asked_urls()
        .iter()
        .filter(|url| url.ends_with("/loop"))
        .count();
    assert_eq!(hops, MAX_REDIRECTS + 1);
}

#[tokio::test]
async fn a_relative_redirect_is_resolved_against_the_page_it_came_from() {
    let fake = Fake::answering(&[
        ("https://news.example/robots.txt", ok("", "text/plain")),
        ("https://news.example/old", redirect("/new")),
        (
            "https://news.example/new",
            ok("<p>Moved here.</p>", "text/html"),
        ),
    ]);
    let mut session = session(fake, clock());
    let answer = session.fetch("https://news.example/old").await;
    assert!(answer.contains("Moved here."), "{answer}");
    assert_eq!(
        page_row(&session).url.as_deref(),
        Some("https://news.example/new")
    );
}

#[tokio::test]
async fn a_site_that_asks_readers_away_is_obeyed_and_the_owner_is_told() {
    let fake = Fake::answering(&[
        (
            "https://news.example/robots.txt",
            ok("User-agent: *\nDisallow: /private\n", "text/plain"),
        ),
        (
            "https://news.example/private/x",
            ok("<p>secret</p>", "text/html"),
        ),
        (
            "https://news.example/public",
            ok("<p>open</p>", "text/html"),
        ),
    ]);
    let mut session = session(fake.clone(), clock());
    let refused = session.fetch("https://news.example/private/x").await;
    assert!(refused.contains("WEB_FETCH_ROBOTS_DENIED"), "{refused}");
    assert!(!refused.contains("secret"), "{refused}");
    let allowed = session.fetch("https://news.example/public").await;
    assert!(allowed.contains("open"), "{allowed}");
    // The robots file is read once for the host, not once per page.
    let robots_reads = fake
        .asked_urls()
        .iter()
        .filter(|url| url.ends_with("robots.txt"))
        .count();
    assert_eq!(robots_reads, 1);
}

#[tokio::test]
async fn the_call_limit_stops_a_run_that_will_not_stop_itself() {
    let fake = Fake::answering(&[(SEARCH_URL, search_answer())]);
    let mut session = session(fake, clock());
    for _ in 0..MAX_TOOL_CALLS {
        assert!(session.exhausted().is_none());
        session.search("uk news").await;
    }
    assert_eq!(session.exhausted(), Some("WEB_TOOL_CALL_LIMIT"));
    let refused = session.search("uk news").await;
    assert!(refused.contains("WEB_TOOL_CALL_LIMIT"), "{refused}");
    assert_eq!(session.records().len(), MAX_TOOL_CALLS);
}

#[tokio::test]
async fn the_run_time_limit_stops_a_run_whose_requests_are_slow() {
    let clock = clock();
    let fake = Fake::slow(&[(SEARCH_URL, search_answer())], clock.clone(), 45);
    let mut session = session(fake, clock);
    session.search("uk news").await;
    session.search("uk news").await;
    assert!(
        session.exhausted().is_none(),
        "ninety seconds is still inside the budget"
    );
    session.search("uk news").await;
    assert_eq!(session.exhausted(), Some("WEB_RUN_TIME_LIMIT"));
    let refused = session.search("uk news").await;
    assert!(refused.contains("WEB_RUN_TIME_LIMIT"), "{refused}");
}

#[tokio::test]
async fn the_run_byte_limit_stops_a_run_reading_very_large_pages() {
    let huge = "x".repeat(MAX_FETCH_BYTES);
    let mut answer = ok(&huge, "text/plain");
    answer.bytes = MAX_FETCH_BYTES;
    let fake = Fake::answering(&[
        ("https://news.example/robots.txt", ok("", "text/plain")),
        ("https://news.example/big", answer),
    ]);
    let mut session = session(fake, clock());
    for _ in 0..4 {
        session.fetch("https://news.example/big").await;
    }
    assert_eq!(session.exhausted(), Some("WEB_RUN_BYTE_LIMIT"));
}

#[tokio::test]
async fn a_search_with_no_working_backend_explains_itself_rather_than_failing_silently() {
    let disabled = WebAccessSettings {
        backend: SearchBackend::Disabled,
        ..keyless()
    };
    let mut session = Session::new(
        disabled,
        Surface::Automation,
        None,
        names(),
        Arc::new(Resolver),
        Fake::answering(&[]),
        clock(),
    );
    let answer = session.search("uk news").await;
    assert!(answer.contains("WEB_SEARCH_DISABLED"), "{answer}");
    assert!(answer.contains("switched off"), "{answer}");
    assert_eq!(session.records()[0].outcome, "refused");
}

#[tokio::test]
async fn a_search_service_that_answers_with_an_error_is_reported_as_a_failure() {
    let mut error = ok("upstream is down", "text/html");
    error.status = 503;
    let fake = Fake::answering(&[(SEARCH_URL, error)]);
    let mut session = session(fake, clock());
    let answer = session.search("uk news").await;
    assert!(answer.contains("WEB_SEARCH_UNAVAILABLE"), "{answer}");
    assert_eq!(session.records()[0].outcome, "failed");
}

#[tokio::test]
async fn every_record_is_json_the_contract_can_carry() {
    let fake = Fake::answering(&[(SEARCH_URL, search_answer())]);
    let mut session = session(fake, clock());
    session.search("uk news").await;
    let value = session.records()[0].to_json();
    assert_eq!(value["tool"], "web_search");
    assert_eq!(value["query"], "uk news");
    assert_eq!(value["outcome"], "succeeded");
    assert_eq!(value["index"], 0);
    assert!(value.get("duration_ms").is_some());
}

#[tokio::test]
async fn a_surface_the_owner_did_not_allow_makes_no_request_at_all() {
    let fake = Fake::answering(&[(SEARCH_URL, search_answer())]);
    let settings = WebAccessSettings {
        policy: crate::web_tools::policy::WebAccessPolicy::AutomationsOnly,
        ..keyless()
    };
    let mut session = Session::new(
        settings,
        Surface::Chat,
        None,
        names(),
        Arc::new(Resolver),
        fake.clone(),
        clock(),
    );
    let answer = session.search("uk news").await;
    assert!(
        answer.contains("WEB_ACCESS_CHATS_NOT_PERMITTED"),
        "{answer}"
    );
    assert!(answer.contains("automations only"), "{answer}");
    let page = session.fetch("https://news.example/one").await;
    assert!(page.contains("WEB_ACCESS_CHATS_NOT_PERMITTED"), "{page}");
    assert!(
        fake.asked_urls().is_empty(),
        "a refused surface still reached the network: {:?}",
        fake.asked_urls()
    );
}

#[tokio::test]
async fn a_denied_domain_is_refused_before_the_page_is_asked_for() {
    let fake = Fake::answering(&[("https://ads.example/one", ok("<p>hi</p>", "text/html"))]);
    let settings = WebAccessSettings {
        deny_domains: vec!["ads.example".to_owned()],
        ..keyless()
    };
    let mut session = Session::new(
        settings,
        Surface::Automation,
        None,
        names(),
        Arc::new(Resolver),
        fake.clone(),
        clock(),
    );
    let page = session.fetch("https://ads.example/one").await;
    assert!(page.contains("WEB_DOMAIN_BLOCKED"), "{page}");
    assert_eq!(session.records()[0].outcome, "refused");
    assert!(
        fake.asked_urls().is_empty(),
        "a denied domain was still asked for: {:?}",
        fake.asked_urls()
    );
}

include!("tests/privacy.rs");

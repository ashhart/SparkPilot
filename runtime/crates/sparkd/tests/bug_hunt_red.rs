//! Red tests for docs/reviews/BUG-HUNT-2026-09-05.md: a still-ignored one names the finding it proves, and a fixed one is enabled and passes.

use std::net::IpAddr;
use std::sync::Arc;

use sparkd::web_tools::backend::{SearchBackend, WebAccessSettings};
use sparkd::web_tools::guard::{Guard, HostResolver, ResolveFailed};
use sparkd::web_tools::outbound::{OwnNames, scan_query, scan_url};
use sparkd::web_tools::policy::Surface;
use sparkd::web_tools::robots::Robots;
use sparkd::web_tools::session::{
    MAX_TOOL_CALLS, Session, TransportRequest, TransportResponse, WebTransport,
};

/// The names a Spark carries out of the box: `--node-name` defaults to "Spark".
fn default_names() -> OwnNames {
    OwnNames {
        node_id: "11111111-2222-3333-4444-555555555555".to_owned(),
        hostname: "Spark".to_owned(),
    }
}

/// A resolver that answers every name with one ordinary public address.
struct PublicResolver;

impl HostResolver for PublicResolver {
    fn resolve(&self, _host: &str) -> Result<Vec<IpAddr>, ResolveFailed> {
        Ok(vec!["93.184.216.34".parse().expect("address")])
    }
}

/// BH-04: a Spark on its default name must not refuse every search containing that name.
#[test]
fn the_default_node_name_does_not_block_ordinary_searches() {
    let own = default_names();
    assert_eq!(
        scan_query("sparkling water recipes", &own),
        None,
        "an everyday question is refused as a device identifier"
    );
    assert_eq!(
        scan_url("https://spark.apache.org/docs/latest/", &own),
        None,
        "a public documentation site is refused as a device identifier"
    );
}

/// BH-06: a run of digits totalling 9-15 across separate numbers is not a telephone number.
#[test]
fn a_question_about_numbers_is_not_a_telephone_number() {
    let own = OwnNames {
        node_id: "11111111-2222-3333-4444-555555555555".to_owned(),
        hostname: "Kitchen Spark".to_owned(),
    };
    assert_eq!(
        scan_query("compare 1024 2048 4096 context windows", &own),
        None
    );
    assert_eq!(
        scan_query("olympics 1992 1996 2000 medal table", &own),
        None
    );
}

/// BH-02: the outbound scan must survive re-encoding, non-ASCII glyphs and payloads outside the query.
#[test]
fn the_outbound_scan_survives_re_encoding() {
    let own = default_names();
    // The scan decodes percent-encoding exactly once, so a second layer walks straight through.
    assert!(
        scan_url("https://collector.test/c?v=owner%2540example.com", &own).is_some(),
        "a double percent-encoded email address is not recognised"
    );
    // Every class is matched on ASCII only.
    assert!(
        scan_query("write to owner\u{FF20}example.com", &own).is_some(),
        "a fullwidth commercial at is not recognised as an email address"
    );
    assert!(
        scan_query(
            "ring \u{0660}\u{0667}\u{0669}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}",
            &own
        )
        .is_some(),
        "Arabic-Indic digits are not recognised as a telephone number"
    );
    // A path or a subdomain carries as much as a query string does.
    assert!(
        scan_url(
            "https://collector.test/b3duZXJAZXhhbXBsZS5jb20gNDExMTExMTExMTExMTExMQ",
            &own
        )
        .is_some(),
        "an encoded payload in the path is not recognised"
    );
    assert!(
        scan_url("https://b3duZXJAZXhhbXBsZS5jb20.collector.test/", &own).is_some(),
        "an encoded payload in the subdomain is not recognised"
    );
}

/// BH-03: IPv6 forms that embed an IPv4 address must be classified before the request goes out.
#[test]
fn ipv6_addresses_that_embed_a_private_v4_address_are_refused() {
    let guard = Guard::new("spark");
    for address in [
        // NAT64 well-known prefix carrying 127.0.0.1.
        "https://[64:ff9b::7f00:1]/",
        // 6to4 carrying 127.0.0.1.
        "https://[2002:7f00:1::]/",
        // 6to4 carrying 192.168.1.1.
        "https://[2002:c0a8:101::]/",
        // Teredo.
        "https://[2001::1]/",
    ] {
        assert!(
            guard.check(address, &PublicResolver).is_err(),
            "{address} was allowed out"
        );
    }
}

/// BH-08: a name ending in a dot must not slip past the local-name list.
#[test]
fn a_trailing_dot_does_not_defeat_the_local_name_list() {
    let guard = Guard::new("spark");
    assert!(
        guard
            .check("https://spark.local./", &PublicResolver)
            .is_err()
    );
    assert!(
        guard
            .check("https://printer.lan./", &PublicResolver)
            .is_err()
    );
}

/// BH-05: a stored search backend must be TLS, or this Spark's own packaged search on loopback.
#[test]
fn a_stored_search_backend_must_be_tls_and_on_this_spark() {
    for url in [
        "http://searx.example.com",
        "http://10.0.0.5:8888",
        "http://192.168.1.1:80",
    ] {
        let settings = WebAccessSettings {
            backend: SearchBackend::Searxng,
            searxng_url: Some(url.to_owned()),
            ..Default::default()
        };
        assert!(
            settings.validate().is_err(),
            "{url} was accepted as a search service, so the query leaves in clear text"
        );
    }
}

/// BH-09: robots.txt wildcard and end-of-path rules are patterns, not literal characters.
#[test]
fn robots_wildcards_are_honoured() {
    let rules = Robots::parse("User-agent: *\nDisallow: /*.pdf$\n");
    assert!(!rules.permits("/reports/2026.pdf"));
    let folder = Robots::parse("User-agent: *\nDisallow: /private/*/secret\n");
    assert!(!folder.permits("/private/a/secret"));
}

/// A transport that answers every request with the same page and counts what it was asked.
#[derive(Debug, Default)]
struct CountingTransport {
    calls: std::sync::atomic::AtomicUsize,
}

#[async_trait::async_trait]
impl WebTransport for CountingTransport {
    async fn get(&self, _request: &TransportRequest) -> Result<TransportResponse, String> {
        self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(TransportResponse {
            status: 200,
            location: None,
            content_type: "text/html".to_owned(),
            body: "<html><body><p>page</p></body></html>".to_owned(),
            bytes: 37,
        })
    }
}

/// BH-01: the rolling-hour web ceiling is shared, so concurrent runs cannot each spend all of it.
#[test]
fn two_runs_started_together_cannot_both_spend_the_whole_hour() {
    let transport = Arc::new(CountingTransport::default());
    let clock: Arc<dyn sparkd::clock::UtcClock> = Arc::new(sparkd::clock::SystemUtcClock);
    let settings = WebAccessSettings {
        policy: sparkd::web_tools::policy::WebAccessPolicy::AutomationsAndChats,
        backend: SearchBackend::Disabled,
        ..Default::default()
    };
    // Both runs read the same "already made" count, because nothing is written until a run ends.
    let allowance = MAX_TOOL_CALLS;
    let mut database = rusqlite::Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut database).unwrap();
    let database = Arc::new(parking_lot::Mutex::new(database));
    let metered: Arc<dyn WebTransport> =
        Arc::new(sparkd::web_tools::audited_transport::AuditedTransport::new(
            database.clone(),
            clock.clone(),
            transport.clone(),
            sparkd::automations::runner::WebActor::schedule(),
            allowance,
        ));
    let mut sessions: Vec<Session> = (0..2)
        .map(|_| {
            Session::new(
                settings.clone(),
                Surface::Chat,
                None,
                default_names(),
                Arc::new(PublicResolver),
                Arc::clone(&metered),
                Arc::clone(&clock),
            )
            .with_hourly_allowance(allowance)
        })
        .collect();
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        for session in sessions.iter_mut() {
            for index in 0..MAX_TOOL_CALLS {
                session
                    .fetch(&format!("https://reference.test/page-{index}"))
                    .await;
            }
        }
    });
    let made = transport.calls.load(std::sync::atomic::Ordering::SeqCst);
    assert!(
        made <= allowance,
        "two runs sharing one hourly allowance of {allowance} made {made} outbound requests"
    );
}

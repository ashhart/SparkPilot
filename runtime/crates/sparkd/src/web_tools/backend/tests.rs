use super::*;

fn settings(backend: SearchBackend) -> WebAccessSettings {
    WebAccessSettings {
        backend,
        ..WebAccessSettings::default()
    }
}

#[test]
fn the_default_backend_is_the_sparks_own_search_and_needs_no_account() {
    let default = WebAccessSettings::default();
    assert_eq!(default.backend, SearchBackend::Searxng);
    assert!(!default.backend.needs_secret());
    assert_eq!(default.validate(), Ok(()));
    let request = search_request(&default, "uk news today", None).expect("a request");
    assert!(
        request.url.starts_with("http://127.0.0.1:18119/search?"),
        "{}",
        request.url
    );
    assert!(request.url.contains("q=uk+news+today"), "{}", request.url);
    assert_eq!(request.secret_header, None);
}

#[test]
fn the_keyless_public_backend_sends_no_account_identifier() {
    let keyless = settings(SearchBackend::DuckDuckGo);
    assert_eq!(keyless.validate(), Ok(()));
    let request = search_request(&keyless, "uk news today", None).expect("a request");
    assert!(
        request
            .url
            .starts_with("https://html.duckduckgo.com/html/?")
    );
    assert_eq!(request.secret_header, None);
}

#[test]
fn a_backend_that_needs_more_from_the_owner_is_refused_before_it_is_stored() {
    let mut brave = settings(SearchBackend::Brave);
    assert_eq!(brave.validate(), Err("WEB_SEARCH_BACKEND_INCOMPLETE"));
    brave.brave_credential_id = Some(Uuid::new_v4());
    assert_eq!(brave.validate(), Ok(()));

    let mut searx = settings(SearchBackend::Searxng);
    searx.searxng_url = None;
    assert_eq!(searx.validate(), Err("WEB_SEARCH_BACKEND_INCOMPLETE"));
    for bad in [
        "not a url",
        "ftp://search.example",
        "https://user:pass@search.example",
        "file:///etc/passwd",
    ] {
        searx.searxng_url = Some(bad.to_owned());
        assert_eq!(
            searx.validate(),
            Err("WEB_SEARCH_BACKEND_INVALID"),
            "{bad} must be refused"
        );
    }
    searx.searxng_url = Some("https://search.example/".to_owned());
    assert_eq!(searx.validate(), Ok(()));
}

#[test]
fn the_owners_key_travels_only_in_the_backend_header_that_needs_it() {
    let mut brave = settings(SearchBackend::Brave);
    brave.brave_credential_id = Some(Uuid::new_v4());
    assert_eq!(
        search_request(&brave, "uk news", None),
        Err("WEB_SEARCH_BACKEND_INCOMPLETE")
    );
    let request = search_request(&brave, "uk news", Some("  secret-key  ")).expect("a request");
    assert_eq!(
        request.secret_header,
        Some(("x-subscription-token", "secret-key".to_owned()))
    );
    assert!(!request.url.contains("secret-key"), "{}", request.url);
}

#[test]
fn a_self_hosted_searxng_is_asked_for_json_at_its_own_base() {
    let mut searx = settings(SearchBackend::Searxng);
    searx.searxng_url = Some("https://search.example/".to_owned());
    let request = search_request(&searx, "uk news", None).expect("a request");
    assert!(
        request.url.starts_with("https://search.example/search?"),
        "{}",
        request.url
    );
    assert!(request.url.contains("format=json"), "{}", request.url);
    assert_eq!(request.accept, "application/json");
}

#[test]
fn a_disabled_backend_refuses_every_search_and_an_empty_query_is_never_sent() {
    assert_eq!(
        search_request(&settings(SearchBackend::Disabled), "news", None),
        Err("WEB_SEARCH_DISABLED")
    );
    for query in ["", "   "] {
        assert_eq!(
            search_request(&WebAccessSettings::default(), query, None),
            Err("WEB_SEARCH_QUERY_INVALID")
        );
    }
    let long = "a".repeat(401);
    assert_eq!(
        search_request(&WebAccessSettings::default(), &long, None),
        Err("WEB_SEARCH_QUERY_INVALID")
    );
}

const DDG: &str = r#"
<div class="result">
<a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fnews.example%2Frates&amp;rut=abc">Bank holds <b>rates</b></a>
<a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fnews.example%2Frates">The bank held rates at 4&nbsp;per cent.</a>
</div>
<div class="result">
<a class="result__a" href="https://other.example/story">Second story</a>
<a class="result__snippet" href="https://other.example/story">A second summary.</a>
</div>
<div class="result result--ad">
<a class="result__a" href="/y.js?ad_provider=x">Sponsored</a>
</div>
"#;

#[test]
fn duckduckgos_click_through_addresses_are_unwrapped_to_the_real_pages() {
    let results = parse_results(SearchBackend::DuckDuckGo, DDG);
    assert_eq!(results.len(), 2, "{results:?}");
    assert_eq!(results[0].url, "https://news.example/rates");
    assert_eq!(results[0].title, "Bank holds rates");
    assert_eq!(results[0].snippet, "The bank held rates at 4 per cent.");
    assert_eq!(results[1].url, "https://other.example/story");
    assert_eq!(results[1].title, "Second story");
}

#[test]
fn a_searxng_answer_is_read_and_a_result_without_a_web_address_is_dropped() {
    let body = r#"{"results":[
        {"title":"Rates held","url":"https://news.example/rates","content":"The bank held rates."},
        {"title":"No address","content":"nothing"},
        {"title":"Bad scheme","url":"file:///etc/passwd","content":"nope"}
    ]}"#;
    let results = parse_results(SearchBackend::Searxng, body);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].url, "https://news.example/rates");
    assert_eq!(results[0].snippet, "The bank held rates.");
}

#[test]
fn a_brave_answer_is_read_from_its_own_shape() {
    let body = r#"{"web":{"results":[
        {"title":"Rates <strong>held</strong>","url":"https://news.example/rates","description":"Held at 4%."}
    ]}}"#;
    let results = parse_results(SearchBackend::Brave, body);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].title, "Rates held");
    assert_eq!(results[0].snippet, "Held at 4%.");
}

#[test]
fn an_answer_that_is_not_what_the_backend_promised_returns_nothing_rather_than_guessing() {
    for backend in [
        SearchBackend::DuckDuckGo,
        SearchBackend::Searxng,
        SearchBackend::Brave,
        SearchBackend::Disabled,
    ] {
        for body in [
            "",
            "not json",
            "<html><body>error</body></html>",
            "{}",
            "[]",
        ] {
            assert!(
                parse_results(backend, body).is_empty(),
                "{} must not invent results from {body:?}",
                backend.name()
            );
        }
    }
}

#[test]
fn a_backend_answer_is_capped_so_one_search_cannot_fill_the_context() {
    let items: Vec<String> = (0..40)
        .map(|index| {
            format!(r#"{{"title":"t{index}","url":"https://news.example/{index}","content":"c"}}"#)
        })
        .collect();
    let body = format!(r#"{{"results":[{}]}}"#, items.join(","));
    assert_eq!(
        parse_results(SearchBackend::Searxng, &body).len(),
        MAX_RESULTS
    );
}

#[test]
fn every_backend_name_round_trips_and_an_unknown_one_is_refused() {
    for backend in [
        SearchBackend::DuckDuckGo,
        SearchBackend::Searxng,
        SearchBackend::Brave,
        SearchBackend::Disabled,
    ] {
        assert_eq!(SearchBackend::parse(backend.name()), Some(backend));
    }
    assert_eq!(SearchBackend::parse("google"), None);
    assert_eq!(SearchBackend::parse(""), None);
}

/// BH-05: cleartext is only ever this Spark's own packaged search, on its own port.
#[test]
fn only_the_packaged_search_on_this_spark_may_be_asked_in_clear_text() {
    let mut searx = settings(SearchBackend::Searxng);
    for accepted in [
        SEARXNG_LOCAL_URL,
        "http://[::1]:18119",
        "https://search.example/",
    ] {
        searx.searxng_url = Some(accepted.to_owned());
        assert_eq!(searx.validate(), Ok(()), "{accepted} must be accepted");
    }
    for refused in [
        "http://searx.example.com",
        "http://10.0.0.5:8888",
        "http://192.168.1.1:80",
        "http://127.0.0.1:8080",
        "http://localhost:18119",
    ] {
        searx.searxng_url = Some(refused.to_owned());
        assert_eq!(
            searx.validate(),
            Err("WEB_SEARCH_BACKEND_INVALID"),
            "{refused} must be refused"
        );
    }
}

/// BH-05: the owner is told why, not merely that the address was refused.
#[test]
fn the_reason_a_search_service_was_refused_says_what_is_wrong_with_it() {
    let explanation = crate::web_tools::policy::explanation("WEB_SEARCH_BACKEND_INVALID");
    assert!(explanation.contains("https"), "{explanation}");
    assert!(explanation.contains("127.0.0.1"), "{explanation}");
}

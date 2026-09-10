use super::*;
use std::collections::HashMap;

/// Answers DNS from a table so every blocked class can be proved without a network.
struct Book(HashMap<String, Vec<IpAddr>>);

impl Book {
    fn with(host: &str, addresses: &[&str]) -> Self {
        let mut table = HashMap::new();
        table.insert(
            host.to_owned(),
            addresses
                .iter()
                .map(|value| value.parse().expect("test address"))
                .collect(),
        );
        Self(table)
    }
}

impl HostResolver for Book {
    fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, ResolveFailed> {
        self.0.get(host).cloned().ok_or(ResolveFailed)
    }
}

fn public() -> Book {
    Book::with(
        "example.com",
        &["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
    )
}

fn guard() -> Guard {
    Guard::new("spark-01")
}

#[test]
fn only_http_and_https_are_followed() {
    for url in [
        "file:///etc/passwd",
        "ftp://example.com/x",
        "gopher://example.com/",
        "data:text/plain,hello",
        "javascript:alert(1)",
        "blob:https://example.com/1",
        "ws://example.com/",
        "chrome://settings",
        "jar:http://example.com!/",
    ] {
        assert_eq!(
            guard().check(url, &public()),
            Err(Refusal::Scheme),
            "{url} must be refused"
        );
    }
    assert!(guard().check("https://example.com/news", &public()).is_ok());
}

#[test]
fn a_url_carrying_credentials_or_an_unusual_port_is_refused() {
    let book = Book::with("example.com", &["93.184.216.34"]);
    assert_eq!(
        guard().check("https://user:secret@example.com/", &book),
        Err(Refusal::Credentials)
    );
    assert_eq!(
        guard().check("https://user@example.com/", &book),
        Err(Refusal::Credentials)
    );
    assert_eq!(
        guard().check("https://example.com:18100/v1/models", &book),
        Err(Refusal::Port)
    );
    assert_eq!(
        guard().check("https://example.com:8443/", &book),
        Err(Refusal::Port)
    );
    assert!(guard().check("https://example.com:443/", &book).is_ok());
}

#[test]
fn every_blocked_address_class_is_refused_as_a_literal_host() {
    for literal in [
        "127.0.0.1",
        "127.1.2.3",
        "0.0.0.0",
        "0.1.2.3",
        "10.1.2.3",
        "172.16.9.9",
        "172.31.255.255",
        "192.168.50.158",
        "169.254.169.254",
        "100.64.0.1",
        "198.18.0.1",
        "192.0.2.1",
        "198.51.100.1",
        "203.0.113.1",
        "192.0.0.1",
        "224.0.0.1",
        "240.0.0.1",
        "255.255.255.255",
    ] {
        let url = format!("https://{literal}/");
        assert_eq!(
            guard().check(&url, &public()),
            Err(Refusal::PrivateAddress),
            "{literal} must be refused"
        );
    }
    for literal in [
        "[::1]",
        "[::]",
        "[fe80::1]",
        "[fc00::1]",
        "[fd12:3456::1]",
        "[ff02::1]",
        "[2001:db8::1]",
        "[::ffff:127.0.0.1]",
        "[::ffff:192.168.1.1]",
        "[::127.0.0.1]",
        // NAT64 64:ff9b::7f00:1 and Teredo 2001::1 are named by bug_hunt_red::ipv6_addresses_that_embed_a_private_v4_address_are_refused.
        "[2002:7f00:1::1]",
        "[2002:c0a8:101::1]",
        "[2002:a9fe:a9fe::1]",
        "[64:ff9b::c0a8:101]",
        "[64:ff9b:1::7f00:1]",
        "[2001:0:4136:e378:8000:63bf:3fff:fdd2]",
        "[2001:2::1]",
        "[2001:10::1]",
    ] {
        let url = format!("https://{literal}/");
        assert_eq!(
            guard().check(&url, &public()),
            Err(Refusal::PrivateAddress),
            "{literal} must be refused"
        );
    }
    assert!(guard().check("https://93.184.216.34/", &public()).is_ok());
    for literal in ["[2002:5db8:d822::1]", "[64:ff9b::5db8:d822]"] {
        let url = format!("https://{literal}/");
        assert!(
            guard().check(&url, &public()).is_ok(),
            "{literal} carries a public address"
        );
    }
}

#[test]
fn a_name_that_resolves_into_blocked_space_is_refused_after_the_lookup() {
    for address in ["127.0.0.1", "192.168.50.158", "169.254.169.254", "::1"] {
        let book = Book::with("news.example", &[address]);
        assert_eq!(
            guard().check("https://news.example/today", &book),
            Err(Refusal::PrivateAddress),
            "a name resolving to {address} must be refused"
        );
    }
}

#[test]
fn one_bad_answer_among_good_ones_still_refuses_the_whole_name() {
    let book = Book::with("news.example", &["93.184.216.34", "127.0.0.1"]);
    assert_eq!(
        guard().check("https://news.example/", &book),
        Err(Refusal::PrivateAddress)
    );
}

#[test]
fn the_sparks_own_names_are_refused_before_any_lookup() {
    let book = Book::with("spark-01.local", &["93.184.216.34"]);
    for host in [
        "localhost",
        "LOCALHOST",
        "spark-01",
        "spark-01.local",
        "printer.local",
        "service.internal",
        "box.localdomain",
    ] {
        let url = format!("https://{host}/");
        assert_eq!(
            guard().check(&url, &book),
            Err(Refusal::LocalName),
            "{host} must be refused"
        );
    }
}

#[test]
fn a_name_with_no_answer_is_refused_rather_than_attempted() {
    let book = Book::with("other.example", &["93.184.216.34"]);
    assert_eq!(
        guard().check("https://news.example/", &book),
        Err(Refusal::Unresolvable)
    );
    let empty = Book::with("news.example", &[]);
    assert_eq!(
        guard().check("https://news.example/", &empty),
        Err(Refusal::Unresolvable)
    );
}

#[test]
fn a_url_that_is_not_a_url_is_refused() {
    for text in [
        "",
        "   ",
        "not a url",
        "https://",
        "https://[",
        "https://example.com:9x/",
    ] {
        assert_eq!(
            guard().check(text, &public()),
            Err(Refusal::Invalid),
            "{text:?} must be refused"
        );
    }
    // WHATWG parsing folds the extra slash away, so this is a bare host and is refused as a local name.
    assert_eq!(
        guard().check("https:///path", &public()),
        Err(Refusal::LocalName)
    );
}

#[test]
fn every_refusal_carries_an_owner_facing_code() {
    for refusal in [
        Refusal::Scheme,
        Refusal::Credentials,
        Refusal::Port,
        Refusal::PrivateAddress,
        Refusal::LocalName,
        Refusal::Unresolvable,
        Refusal::Invalid,
    ] {
        assert!(refusal.code().starts_with("WEB_FETCH_"), "{refusal:?}");
        assert!(!refusal.explanation().is_empty(), "{refusal:?}");
    }
    assert_eq!(Refusal::PrivateAddress.code(), "WEB_FETCH_PRIVATE_ADDRESS");
    assert_eq!(Refusal::LocalName.code(), "WEB_FETCH_PRIVATE_ADDRESS");
    assert_eq!(Refusal::Scheme.code(), "WEB_FETCH_SCHEME_BLOCKED");
}

#[test]
fn a_permitted_destination_keeps_the_addresses_that_were_checked() {
    let destination = guard()
        .check("https://example.com/news", &public())
        .expect("public destination");
    assert_eq!(destination.host, "example.com");
    assert_eq!(destination.addresses.len(), 2);
    assert_eq!(destination.url.as_str(), "https://example.com/news");
}

#[test]
fn a_page_is_only_ever_read_over_tls() {
    // The owner's rule is "GET only, TLS only"; a cleartext fetch is readable in transit.
    for url in [
        "http://example.com/news",
        "http://example.com:80/news",
        "http://93.184.216.34/",
    ] {
        assert_eq!(
            guard().check(url, &public()),
            Err(Refusal::Scheme),
            "{url} must be refused"
        );
    }
    assert!(guard().check("https://example.com/news", &public()).is_ok());
}

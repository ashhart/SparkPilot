use super::*;
use crate::web_tools::backend::SearchBackend;

fn settings(policy: WebAccessPolicy, harness: bool) -> WebAccessSettings {
    WebAccessSettings {
        policy,
        harness_access: harness,
        backend: SearchBackend::Searxng,
        searxng_url: Some("http://127.0.0.1:18119".to_owned()),
        brave_credential_id: None,
        allow_domains: Vec::new(),
        deny_domains: Vec::new(),
        updated_at: 0,
    }
}

#[test]
fn test_the_default_policy_lets_nothing_reach_the_internet() {
    let settings = settings(WebAccessPolicy::default(), false);
    for surface in [Surface::Automation, Surface::Chat, Surface::Harness] {
        assert_eq!(
            permits(&settings, surface),
            Err("WEB_ACCESS_POLICY_OFF"),
            "{} was allowed under the default policy",
            surface.name()
        );
    }
}

#[test]
fn test_automations_only_refuses_chats_and_harnesses() {
    let settings = settings(WebAccessPolicy::AutomationsOnly, false);
    assert_eq!(permits(&settings, Surface::Automation), Ok(()));
    assert_eq!(
        permits(&settings, Surface::Chat),
        Err("WEB_ACCESS_CHATS_NOT_PERMITTED")
    );
    assert_eq!(
        permits(&settings, Surface::Harness),
        Err("WEB_ACCESS_HARNESS_NOT_PERMITTED")
    );
}

#[test]
fn test_a_harness_needs_its_own_policy_value_even_when_chats_are_allowed() {
    let open = settings(WebAccessPolicy::AutomationsAndChats, false);
    assert_eq!(permits(&open, Surface::Chat), Ok(()));
    assert_eq!(
        permits(&open, Surface::Harness),
        Err("WEB_ACCESS_HARNESS_NOT_PERMITTED"),
        "the gateway gained the web tools from the chats policy alone"
    );
    let allowed = settings(WebAccessPolicy::AutomationsAndChats, true);
    assert_eq!(permits(&allowed, Surface::Harness), Ok(()));
}

#[test]
fn test_the_harness_value_alone_never_opens_the_gateway() {
    for policy in [WebAccessPolicy::Off, WebAccessPolicy::AutomationsOnly] {
        assert!(
            permits(&settings(policy, true), Surface::Harness).is_err(),
            "the gateway opened under policy {}",
            policy.name()
        );
    }
}

#[test]
fn test_policy_names_survive_a_round_trip() {
    for policy in [
        WebAccessPolicy::Off,
        WebAccessPolicy::AutomationsOnly,
        WebAccessPolicy::AutomationsAndChats,
    ] {
        assert_eq!(WebAccessPolicy::parse(policy.name()), Some(policy));
    }
    assert_eq!(WebAccessPolicy::parse("everything"), None);
}

#[test]
fn test_a_deny_entry_covers_the_name_and_everything_under_it() {
    let mut settings = settings(WebAccessPolicy::AutomationsAndChats, false);
    settings.deny_domains = vec!["tracker.example".to_owned()];
    assert!(!domain_permitted(&settings, "tracker.example"));
    assert!(!domain_permitted(&settings, "a.b.tracker.example"));
    assert!(!domain_permitted(&settings, "TRACKER.EXAMPLE."));
    assert!(
        domain_permitted(&settings, "nottracker.example"),
        "a name that merely ends the same way was treated as a subdomain"
    );
}

#[test]
fn test_an_allow_list_refuses_everything_it_does_not_name() {
    let mut settings = settings(WebAccessPolicy::AutomationsAndChats, false);
    settings.allow_domains = vec!["bbc.co.uk".to_owned()];
    assert!(domain_permitted(&settings, "www.bbc.co.uk"));
    assert!(!domain_permitted(&settings, "example.com"));
    settings.deny_domains = vec!["ads.bbc.co.uk".to_owned()];
    assert!(
        !domain_permitted(&settings, "ads.bbc.co.uk"),
        "a denied name inside an allowed domain was still read"
    );
}

#[test]
fn test_a_domain_entry_must_be_a_bare_name() {
    assert_eq!(validate_domains(&["bbc.co.uk".to_owned()]), Ok(()));
    for bad in [
        "https://bbc.co.uk",
        "bbc.co.uk/news",
        "localhost",
        ".bbc.co.uk",
        "bbc.co.uk.",
        "bbc co uk",
        "",
    ] {
        assert_eq!(
            validate_domains(&[bad.to_owned()]),
            Err("WEB_DOMAIN_ENTRY_INVALID"),
            "{bad:?} was accepted as a domain"
        );
    }
    let many = vec!["a.example".to_owned(); MAX_DOMAIN_ENTRIES + 1];
    assert_eq!(validate_domains(&many), Err("WEB_DOMAIN_LIST_TOO_LONG"));
}

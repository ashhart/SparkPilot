use super::*;

fn own() -> OwnNames {
    OwnNames {
        node_id: "6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31".to_owned(),
        hostname: "spark-hallway".to_owned(),
    }
}

#[test]
fn test_an_ordinary_question_and_an_ordinary_address_leave_the_house() {
    for query in [
        "uk news today",
        "iPhone 17 Pro release date",
        "weather in Bristol tomorrow",
        "what happened in parliament this week",
    ] {
        assert_eq!(scan_query(query, &own()), None, "{query:?} was blocked");
    }
    for url in [
        "https://www.bbc.co.uk/news",
        "https://news.example/2026/09/05/1234567890/parliament-vote",
        "https://example.com/articles/a-very-long-slug-about-the-weather",
    ] {
        assert_eq!(scan_url(url, &own()), None, "{url} was blocked");
    }
}

#[test]
fn test_an_email_address_never_reaches_a_search_service() {
    assert_eq!(
        scan_query("alex.taylor@example.com invoice", &own()),
        Some(Finding::EmailAddress)
    );
    assert_eq!(
        scan_url(
            "https://collect.example/?to=alex.taylor@example.com",
            &own()
        ),
        Some(Finding::EmailAddress)
    );
}

#[test]
fn test_a_telephone_number_is_recognised_however_it_is_written() {
    for text in [
        "+44 7700 900123",
        "07700 900123",
        "(020) 7946 0958",
        "call 07700900123 back",
    ] {
        assert_eq!(
            scan_query(text, &own()),
            Some(Finding::PhoneNumber),
            "{text:?} was sent"
        );
    }
}

#[test]
fn test_a_card_number_is_recognised_before_a_phone_number_is() {
    assert_eq!(
        scan_query("4242 4242 4242 4242", &own()),
        Some(Finding::PaymentCard)
    );
    assert_eq!(
        scan_url("https://collect.example/p/4242424242424242", &own()),
        Some(Finding::PaymentCard)
    );
}

#[test]
fn test_a_key_or_token_is_recognised_by_its_shape() {
    for text in [
        "sk-abcdefghijklmnopqrstuvwxyz012345",
        "ghp_16CharactersAndMoreHere0000",
        "AKIAIOSFODNN7EXAMPLE",
        "-----BEGIN PRIVATE KEY-----",
        "hf_QWERTYuiopASDFGHjklZXCVB",
    ] {
        assert_eq!(
            scan_query(text, &own()),
            Some(Finding::Secret),
            "{text:?} was sent"
        );
    }
}

#[test]
fn test_this_sparks_own_names_are_treated_as_identifiers() {
    assert_eq!(
        scan_query("status of 6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31", &own()),
        Some(Finding::Identifier)
    );
    assert_eq!(
        scan_query("spark-hallway logs", &own()),
        Some(Finding::Identifier)
    );
    assert_eq!(
        scan_url(
            "https://collect.example/?id=6f2c1a449c1e4a3b8f102b7d5e9a0c31",
            &own()
        ),
        Some(Finding::Identifier)
    );
}

#[test]
fn test_percent_encoding_does_not_hide_a_value_in_an_address() {
    assert_eq!(
        scan_url(
            "https://collect.example/?q=alex.taylor%40example.com",
            &own()
        ),
        Some(Finding::EmailAddress),
        "an encoded address slipped through"
    );
    assert_eq!(
        scan_url("https://collect.example/?q=%2B44%207700%20900123", &own()),
        Some(Finding::PhoneNumber)
    );
}

#[test]
fn test_an_article_path_may_carry_digits_but_a_query_string_may_not() {
    assert_eq!(
        scan_url("https://news.example/2026/09/05/908070605040302", &own()),
        None,
        "an ordinary article path was blocked"
    );
    assert_eq!(
        scan_url("https://collect.example/?v=908070605040302", &own()),
        Some(Finding::PhoneNumber),
        "a bare digit run in a query string was sent"
    );
}

#[test]
fn test_an_over_long_question_or_address_is_refused_rather_than_truncated() {
    let long_query = "a ".repeat(MAX_QUERY_LENGTH);
    assert_eq!(scan_query(&long_query, &own()), Some(Finding::TooLong));
    let long_url = format!("https://news.example/{}", "a".repeat(MAX_URL_LENGTH));
    assert_eq!(scan_url(&long_url, &own()), Some(Finding::TooLong));
}

/// BH-06: the separator patterns people actually write telephone numbers in are still caught.
#[test]
fn test_a_written_telephone_number_is_still_recognised_after_the_digit_run_fix() {
    for text in [
        "+44 20 7946 0958",
        "(415) 555-2671",
        "07700 900123",
        "call 415-555-2671 today",
        "+1 (415) 555-2671",
    ] {
        assert_eq!(
            scan_query(text, &own()),
            Some(Finding::PhoneNumber),
            "{text:?} was sent"
        );
    }
}

/// BH-06: separate numbers written next to each other are separate numbers.
#[test]
fn test_several_numbers_in_one_question_are_not_one_telephone_number() {
    for text in [
        "compare 1024 2048 4096 context windows",
        "olympics 1992 1996 2000 medal table",
        "population 1801 1901 2001 census",
        "meeting on 2026-09-05 12 people",
    ] {
        assert_eq!(scan_query(text, &own()), None, "{text:?} was blocked");
    }
}

/// BH-04: an ordinary word an owner names a Spark carries no identifying power.
#[test]
fn test_an_ordinary_node_name_does_not_refuse_ordinary_questions() {
    for name in ["Spark", "Home", "Desk", "Study", "Office", "Lab", "Box"] {
        let own = OwnNames {
            node_id: "6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31".to_owned(),
            hostname: name.to_owned(),
        };
        let query = format!("{} energy drink review", name.to_lowercase());
        assert_eq!(scan_query(&query, &own), None, "{query:?} was blocked");
    }
}

/// BH-04: a distinctive name is still refused, and only as a whole word.
#[test]
fn test_a_distinctive_node_name_is_still_an_identifier_on_a_word_boundary() {
    let own = OwnNames {
        node_id: "6f2c1a44-9c1e-4a3b-8f10-2b7d5e9a0c31".to_owned(),
        hostname: "hallway-01".to_owned(),
    };
    assert_eq!(
        scan_query("hallway-01 logs", &own),
        Some(Finding::Identifier)
    );
    assert_eq!(scan_query("hallway-011 paint", &own), None);
}

/// BH-02: percent-encoding is peeled to a fixed point, and text that stays encoded is refused.
#[test]
fn test_layered_encoding_is_peeled_and_then_refused() {
    assert_eq!(
        scan_url("https://collect.example/?v=owner%252540example.com", &own()),
        Some(Finding::EmailAddress),
        "a triple-encoded address slipped through"
    );
    let deep = "https://collect.example/?v=%".to_owned() + &"25".repeat(5) + "40";
    assert_eq!(scan_url(&deep, &own()), Some(Finding::Obscured));
}

/// BH-02: a decimal digit is a decimal digit in every script, and NFKC folds the lookalike glyphs.
#[test]
fn test_non_ascii_digits_and_glyphs_are_read_as_what_they_mean() {
    assert_eq!(
        scan_query("write to owner\u{FF20}example.com", &own()),
        Some(Finding::EmailAddress)
    );
    for digits in [
        "\u{0660}\u{0667}\u{0669}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}",
        "\u{0966}\u{096D}\u{096F}\u{0967}\u{0968}\u{0969}\u{096A}\u{096B}\u{096C}\u{096D}\u{096E}",
        "\u{FF10}\u{FF17}\u{FF19}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}\u{FF18}",
    ] {
        assert_eq!(
            scan_query(&format!("ring {digits} back"), &own()),
            Some(Finding::PhoneNumber),
            "{digits:?} was sent"
        );
    }
}

/// BH-02: an encoded payload carries as much in a path or a subdomain as it does in a query string.
#[test]
fn test_a_payload_in_the_path_or_the_host_is_refused() {
    assert_eq!(
        scan_url(
            "https://collector.test/b3duZXJAZXhhbXBsZS5jb20gNDExMTExMTExMTExMTExMQ",
            &own()
        ),
        Some(Finding::Secret)
    );
    assert_eq!(
        scan_url("https://b3duZXJAZXhhbXBsZS5jb20.collector.test/", &own()),
        Some(Finding::Secret)
    );
    assert_eq!(
        scan_url("https://en.wikipedia.org/wiki/Espa%C3%B1a", &own()),
        None,
        "an ordinary encoded page title was blocked"
    );
}

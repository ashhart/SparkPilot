//! Fuzz proxy allowlist/model binding and bounded chunk-independent usage scanning, abandoning oversized lines rather than parsing their tails.

mod fuzz_support;

use axum::http::StatusCode;
use serde_json::{Map, Value, json};
use sparkd::engine_api::{UsageScanner, parse_chat};

use fuzz_support::{HOSTILE_STRINGS, Lcg, body_corpus, chunkings, regressions};

/// Seed for client bodies driven at the boundary.
const BOUNDARY_SEED: u64 = 0x5052_4F58_5942_494E; // "PROXYBIN"
/// Seed for upstream frame bytes driven at the usage scanner.
const STREAM_SEED: u64 = 0x5354_5245_414D_5343; // "STREAMSC"
const BOUNDARY_CASES: usize = 20_000;
const STREAM_CASES: usize = 2_000;

/// The engine this harness pretends is loaded.
const SERVED_NAME: &str = "spark-active-model";
const MODEL_ID: &str = "example/model-32b";

/// Pin the expected forward allowlist independently of runtime declarations so accidental widening fails.
const EXPECTED_ALLOWLIST: &[&str] = &[
    "model",
    "messages",
    "stream",
    "temperature",
    "top_p",
    "max_tokens",
    "tools",
    "tool_choice",
    "response_format",
    "user",
    "metadata",
    "stream_options",
];

/// Never forward client-selected engines, credentials or executable-code options.
const NEVER_FORWARDED: &[&str] = &[
    "api_base",
    "base_url",
    "url",
    "endpoint",
    "host",
    "port",
    "path",
    "headers",
    "api_key",
    "authorization",
    "bearer",
    "token",
    "credentials",
    "trust_remote_code",
    "model_path",
    "served_model_name",
    "chat_template",
    "extra_body",
    "guided_json",
    "guided_regex",
    "guided_choice",
    "chat_template_kwargs",
    "detokenize",
    "skip_special_tokens",
];

/// Attach hostile fields to otherwise ordinary chat requests.
fn hostile_chat(rng: &mut Lcg) -> Vec<u8> {
    let mut object = Map::new();
    object.insert(
        "model".to_owned(),
        Value::String(match rng.below(4) {
            0 => SERVED_NAME.to_owned(),
            1 => MODEL_ID.to_owned(),
            2 => rng.pick(HOSTILE_STRINGS).to_owned(),
            _ => "some-other-model".to_owned(),
        }),
    );
    object.insert(
        "messages".to_owned(),
        json!([{"role": "user", "content": rng.pick(HOSTILE_STRINGS)}]),
    );
    for _ in 0..1 + rng.below(3) {
        let key = rng.pick(NEVER_FORWARDED).to_owned();
        object.insert(
            key,
            match rng.below(3) {
                0 => Value::Bool(true),
                1 => Value::String("http://attacker.invalid/v1".to_owned()),
                _ => json!({"nested": rng.pick(HOSTILE_STRINGS)}),
            },
        );
    }
    if rng.below(2) == 0 {
        object.insert("stream".to_owned(), Value::Bool(rng.below(2) == 0));
    }
    Value::Object(object).to_string().into_bytes()
}

/// Nothing but the allowlist crosses, and the model is always the loaded one.
#[test]
fn only_the_allowlist_reaches_the_engine() {
    let mut rng = Lcg::new(BOUNDARY_SEED);
    let mut forwarded_count = 0usize;
    let mut refused_count = 0usize;
    let mut cases: Vec<fuzz_support::Case> = body_corpus(
        BOUNDARY_SEED,
        BOUNDARY_CASES,
        &[
            "model",
            "messages",
            "stream",
            "temperature",
            "tools",
            "metadata",
            "api_base",
            "api_key",
            "trust_remote_code",
            "guided_json",
        ],
        &json!({"model": SERVED_NAME, "messages": [], "stream": false, "temperature": 0.2})
            .to_string(),
    );
    for index in 0..BOUNDARY_CASES / 4 {
        cases.push(fuzz_support::Case {
            label: format!("hostile_chat#{index}"),
            bytes: hostile_chat(&mut rng),
        });
    }
    cases.extend(regressions("proxy_bodies"));

    for case in &cases {
        match parse_chat(&case.bytes).and_then(|request| {
            // Supply a served name only after admission accepts the requested model identity.
            if request.requested_model != SERVED_NAME && request.requested_model != MODEL_ID {
                return Err((
                    StatusCode::NOT_FOUND,
                    axum::Json(json!({"error": {"code": "MODEL_NOT_LOADED"}})),
                ));
            }
            request.upstream_body(SERVED_NAME)
        }) {
            Err((status, body)) => {
                refused_count += 1;
                assert!(
                    status.is_client_error(),
                    "{} was refused with {status}",
                    case.label
                );
                let code = body.0["error"]["code"].as_str().unwrap_or_default();
                assert!(
                    !code.is_empty(),
                    "{} was refused without a code",
                    case.label
                );
            }
            Ok(upstream_body) => {
                forwarded_count += 1;
                let value: Value = serde_json::from_slice(&upstream_body)
                    .unwrap_or_else(|_| panic!("{} produced a non-JSON upstream body", case.label));
                let object = value.as_object().unwrap_or_else(|| {
                    panic!("{} produced a non-object upstream body", case.label)
                });
                for key in object.keys() {
                    assert!(
                        EXPECTED_ALLOWLIST.contains(&key.as_str()),
                        "{} put {key:?} in the upstream body",
                        case.label
                    );
                    assert!(
                        !NEVER_FORWARDED.contains(&key.as_str()),
                        "{} forwarded {key:?}",
                        case.label
                    );
                }
                assert_eq!(
                    object.get("model").and_then(Value::as_str),
                    Some(SERVED_NAME),
                    "{} reached the engine under a model name of its own choosing",
                    case.label
                );
            }
        }
    }
    assert!(
        refused_count > cases.len() / 2,
        "only {refused_count} of {} cases were refused",
        cases.len()
    );
    assert!(
        forwarded_count > 0,
        "no case was ever forwarded, so the allowlist was never exercised"
    );
}

/// Refuse banned parameters explicitly rather than silently dropping requested behavior.
#[test]
fn a_banned_parameter_is_refused_rather_than_dropped() {
    for banned in [
        "guided_json",
        "guided_regex",
        "guided_choice",
        "chat_template_kwargs",
        "detokenize",
        "skip_special_tokens",
    ] {
        let body = json!({"model": SERVED_NAME, "messages": [], banned: true}).to_string();
        let error = parse_chat(body.as_bytes())
            .err()
            .unwrap_or_else(|| panic!("{banned} was accepted"));
        assert_eq!(error.0, StatusCode::BAD_REQUEST, "{banned}");
        assert_eq!(error.1.0["error"]["code"], "MODEL_RECIPE_INVALID");
    }
}

/// Preserve a wrong requested model through parsing for admission to refuse without altering engine accounting.
#[test]
fn a_request_for_another_model_carries_that_name_into_admission() {
    for body in [
        json!({"messages": []}).to_string(),
        json!({"model": Value::Null, "messages": []}).to_string(),
        json!({"model": "", "messages": []}).to_string(),
        json!({"model": format!("{SERVED_NAME} "), "messages": []}).to_string(),
        json!({"model": SERVED_NAME.to_uppercase(), "messages": []}).to_string(),
        json!({"model": 7, "messages": []}).to_string(),
        "[]".to_owned(),
        "null".to_owned(),
    ] {
        let request = parse_chat(body.as_bytes())
            .unwrap_or_else(|_| panic!("{body} should parse; the model check is admission's"));
        assert_ne!(request.requested_model, SERVED_NAME, "{body}");
        assert_ne!(request.requested_model, MODEL_ID, "{body}");
    }
    // Preserve both accepted model aliases too, proving parsing retains identities rather than discarding them.
    for name in [SERVED_NAME, MODEL_ID] {
        let body = json!({"model": name, "messages": []}).to_string();
        assert_eq!(parse_chat(body.as_bytes()).unwrap().requested_model, name);
    }
}

/// Pin loopback URL construction and absence of client-header input at the proxy's source boundary.
#[test]
fn the_proxy_can_only_reach_the_loopback_engine() {
    let source_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut source =
        std::fs::read_to_string(source_root.join("engine_api.rs")).expect("engine_api source");
    for entry in std::fs::read_dir(source_root.join("engine_api")).expect("proxy modules") {
        let path = entry.expect("proxy module entry").path();
        if path.extension().is_some_and(|extension| extension == "rs")
            && !path
                .file_stem()
                .unwrap()
                .to_string_lossy()
                .ends_with("_tests")
        {
            source.push_str(&std::fs::read_to_string(path).expect("proxy module source"));
        }
    }
    let mut urls = 0usize;
    for line in source.lines() {
        let Some(start) = line.find("http://") else {
            continue;
        };
        urls += 1;
        assert!(
            line[start..].starts_with("http://127.0.0.1:"),
            "the proxy builds a non-loopback URL: {}",
            line.trim()
        );
    }
    assert!(
        urls > 0,
        "no URL was found; the pin stopped pinning anything"
    );

    let signature = source
        .split_once("pub async fn chat_completions(")
        .expect("chat_completions")
        .1;
    let signature = &signature[..signature.find(')').expect("signature end")];
    assert!(
        !signature.contains("HeaderMap"),
        "the proxy handler takes client headers: {signature}"
    );
}

/// Require chunk-independent usage counts and buffering no larger than one capped line.
#[test]
fn the_usage_scanner_is_chunk_independent_and_bounded() {
    let mut rng = Lcg::new(STREAM_SEED);
    let mut cases: Vec<Vec<u8>> = Vec::new();
    for index in 0..STREAM_CASES {
        let mut stream = Vec::new();
        for _ in 0..1 + rng.below(6) {
            let total = rng.next_u64() % 10_000;
            let frame = match rng.below(6) {
                0 => format!(
                    "data: {{\"usage\":{{\"total_tokens\":{total},\"prompt_tokens\":1,\"completion_tokens\":2}}}}\n\n"
                ),
                1 => "data: [DONE]\n\n".to_owned(),
                2 => ": heartbeat\n\n".to_owned(),
                3 => format!("data: {}\n\n", rng.pick(HOSTILE_STRINGS)),
                4 => format!(
                    "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{}\"}}}}]}}\n\n",
                    rng.pick(HOSTILE_STRINGS).escape_debug()
                ),
                _ => String::from_utf8_lossy(&rng.bytes(1 + index % 64)).into_owned(),
            };
            stream.extend_from_slice(frame.as_bytes());
        }
        cases.push(stream);
    }
    for case in regressions("sse_frames") {
        cases.push(case.bytes);
    }

    for (index, case) in cases.iter().enumerate() {
        let mut reference = UsageScanner::default();
        reference.scan_frame(case);
        let expected = reference.total_tokens();
        for chunks in chunkings(&mut rng, case) {
            let mut scanner = UsageScanner::default();
            for chunk in chunks {
                scanner.scan_frame(&chunk);
                assert!(
                    scanner.buffered() <= 256 * 1024,
                    "case {index} made the scanner hold {} bytes",
                    scanner.buffered()
                );
            }
            assert_eq!(
                expected,
                scanner.total_tokens(),
                "case {index} counted differently when chunked"
            );
        }
    }
}

/// Discard oversized lines through newline so a forged usage object hidden behind padding cannot become accounting evidence.
#[test]
fn a_forged_usage_object_behind_an_over_long_line_is_not_counted() {
    // Place the forgery in exactly the final 256 KiB so an implementation retaining oversized-line tails would parse it.
    const CAP: usize = 256 * 1024;
    let head = "{\"usage\":{\"total_tokens\":999999,\"prompt_tokens\":1,\"completion_tokens\":2},\"pad\":\"";
    let tail = "\"}";
    let padding = CAP - head.len() - tail.len();
    let forged = format!("{head}{}{tail}", "x".repeat(padding));
    assert_eq!(forged.len(), CAP, "the forged object must fill the window");
    assert!(
        serde_json::from_str::<Value>(&forged).is_ok(),
        "the forged tail must be parseable, or the mutation proves nothing"
    );

    let mut stream = Vec::new();
    stream.extend_from_slice(b"data: ");
    stream.extend(std::iter::repeat_n(b'p', 64 * 1024));
    stream.extend_from_slice(forged.as_bytes());
    stream.extend_from_slice(b"\n\n");

    let mut scanner = UsageScanner::default();
    scanner.scan_frame(&stream);
    assert_eq!(
        scanner.total_tokens(),
        None,
        "usage hidden in the tail of an over-long line was counted"
    );

    // Resume scanning after the newline and count the subsequent valid usage frame.
    let honest =
        "data: {\"usage\":{\"total_tokens\":7,\"prompt_tokens\":3,\"completion_tokens\":4}}\n\n";
    scanner.scan_frame(honest.as_bytes());
    assert_eq!(scanner.total_tokens(), Some(7));
}

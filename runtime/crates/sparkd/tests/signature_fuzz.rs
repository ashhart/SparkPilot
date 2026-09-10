//! Fuzz SPARK2 injectivity and delimiter exclusion over legal HTTP inputs, rebuilding the shared Apple vectors byte-for-byte.

const SIGNING_NODE_ID: uuid::Uuid = uuid::Uuid::from_u128(2);

mod fuzz_support;

use std::collections::HashSet;

use axum::http::{HeaderValue, Uri};
use p256::ecdsa::signature::{Signer as _, Verifier as _};
use serde_json::{Value, json};
use sparkd::auth::canonical;
use sparkd::crypto::{base64url_encode, sha256_hex};

use fuzz_support::{HOSTILE_STRINGS, Lcg};

/// Seed for the committed cross-language vectors.
const VECTOR_SEED: u64 = 0x5349_474E_5645_4354; // "SIGNVECT"
/// Seed for the property corpus that never leaves this process.
const PROPERTY_SEED: u64 = 0x4341_4E4F_4E49_4341; // "CANONICA"
/// Keep 128 cross-language vectors to cover every field position without inflating the copied Apple test bundle.
const VECTOR_CASES: usize = 128;
/// Tuples generated for the injectivity and mutation properties.
const PROPERTY_CASES: usize = 20_000;

/// Real route shapes, with the parameter positions a signed request uses.
const PATHS: &[&str] = &[
    "/api/v1/status",
    "/api/v1/telemetry",
    "/api/v1/telemetry/history",
    "/api/v1/models",
    "/api/v1/inference/load",
    "/api/v1/inference/load/preview",
    "/api/v1/settings/telemetry",
    "/api/v1/devices/9f1c2f4e-6a3b-4d21-9f60-3f7c1a4d5e60",
    "/api/v1/operations/2b7f0a11-0c9d-4f3a-8b21-6e5d4c3b2a19",
    "/api/v1/projects/7c1d9e33-2f44-4a55-9b66-8d7e6f5a4b3c/changes",
    "/v1/chat/completions",
];

/// Generate legitimate queries including percent-encoded hostile values.
fn query(rng: &mut Lcg) -> String {
    match rng.below(6) {
        0 => String::new(),
        1 => "?limit=100".to_owned(),
        2 => "?resolution=minute&since=2026-08-31T00%3A00%3A00Z".to_owned(),
        3 => format!("?name={}", percent_encode(rng.pick(HOSTILE_STRINGS))),
        4 => format!(
            "?a={}&b={}",
            percent_encode(rng.pick(HOSTILE_STRINGS)),
            rng.next_u64()
        ),
        _ => format!(
            "?cursor={}",
            base64url_encode(&rng.next_u64().to_be_bytes())
        ),
    }
}

/// Encode query values strictly so every generated request remains valid for transport.
fn percent_encode(text: &str) -> String {
    let mut out = String::new();
    for byte in text.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// One generated request. Every field is what a client would send.
struct Request {
    method: String,
    path_and_query: String,
    timestamp: String,
    nonce: String,
    device_id: uuid::Uuid,
    body: String,
}

impl Request {
    fn generate(rng: &mut Lcg) -> Self {
        let method =
            (*rng.pick(&["GET", "POST", "PATCH", "PUT", "DELETE", "post", "get"])).to_owned();
        let path = rng.pick(PATHS);
        // A fixed epoch, not the clock: the vectors must be the same in 2027.
        let seconds = 1_772_000_000 + (rng.next_u64() % 31_536_000) as i64;
        let stamp = time::OffsetDateTime::from_unix_timestamp(seconds).unwrap();
        Self {
            method,
            path_and_query: format!("{path}{}", query(rng)),
            timestamp: stamp
                .format(&time::format_description::well_known::Rfc3339)
                .unwrap(),
            nonce: base64url_encode(&rng.bytes(24)),
            device_id: uuid::Uuid::from_u128(
                (u128::from(rng.next_u64()) << 64) | u128::from(rng.next_u64()),
            ),
            body: match rng.below(4) {
                0 => String::new(),
                1 => json!({"functional": true}).to_string(),
                2 => json!({"name": rng.pick(HOSTILE_STRINGS)}).to_string(),
                _ => json!({"messages": [{"role": "user", "content": rng.pick(HOSTILE_STRINGS)}]})
                    .to_string(),
            },
        }
    }

    fn digest(&self) -> String {
        sha256_hex(self.body.as_bytes())
    }

    fn canonical(&self) -> String {
        canonical(
            &self.method,
            &self.path_and_query,
            &self.timestamp,
            &self.nonce,
            &self.digest(),
            &self.device_id,
            &SIGNING_NODE_ID,
        )
    }

    fn to_case(&self, index: usize) -> Value {
        let canonical = self.canonical();
        json!({
            "name": format!("generated-{index:03}"),
            "request": {
                "method": self.method,
                "path_and_query": self.path_and_query,
                "timestamp": self.timestamp,
                "nonce": self.nonce,
                "device_id": self.device_id.to_string(),
                "node_id": SIGNING_NODE_ID.to_string(),
                "body": self.body,
            },
            "content_sha256": self.digest(),
            "canonical": canonical,
            "canonical_sha256": sha256_hex(canonical.as_bytes()),
        })
    }
}

fn vector_document() -> Value {
    let mut rng = Lcg::new(VECTOR_SEED);
    let cases: Vec<Value> = (0..VECTOR_CASES)
        .map(|index| Request::generate(&mut rng).to_case(index))
        .collect();
    json!({
        "$comment": "Generated cross-language vectors for SPARK2 canonicalisation. \
                     Rebuilt from the seed by sparkd's signature_fuzz test and rebuilt \
                     from the file by the Apple side, so the two implementations cannot \
                     drift apart silently. Do not hand-edit: regenerate with \
                     SPARK_FUZZ_WRITE_VECTORS=1 cargo test -p sparkd --test signature_fuzz.",
        "seed": format!("{VECTOR_SEED:#018x}"),
        "generator": "runtime/crates/sparkd/tests/signature_fuzz.rs",
        "cases": cases,
    })
}

fn fixture_path(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../contracts/fixtures")
        .join(name)
}

fn apple_fixture_path(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../apple/Packages/SparkBootstrap/Tests/SparkBootstrapTests/Fixtures")
        .join(name)
}

/// Require committed vectors to equal deterministic generation, rejecting hand-edited drift.
#[test]
fn the_committed_vectors_are_what_the_seed_produces() {
    let document = vector_document();
    let rendered = format!("{}\n", serde_json::to_string_pretty(&document).unwrap());
    let path = fixture_path("request-signing-fuzz.json");
    if std::env::var("SPARK_FUZZ_WRITE_VECTORS").is_ok() {
        std::fs::write(&path, &rendered).expect("write vectors");
        std::fs::write(apple_fixture_path("request-signing-fuzz.json"), &rendered)
            .expect("write apple vectors");
    }
    let committed = std::fs::read_to_string(&path).expect("committed vectors");
    assert_eq!(
        committed, rendered,
        "the committed vectors are not what {VECTOR_SEED:#x} produces; regenerate with \
         SPARK_FUZZ_WRITE_VECTORS=1"
    );
}

/// Compare SwiftPM's bundled fixture copies exactly with the canonical shared files.
#[test]
fn the_apple_copy_of_every_shared_fixture_is_identical() {
    for name in [
        "request-signing-fuzz.json",
        "request-signing-canonicalization.json",
        "pairing-invitation-canonicalization.json",
        "user-presence-canonicalization.json",
        "presence-key-enrollment-canonicalization.json",
        "pairing-presence-key-canonicalization.json",
        "release-manifest-canonicalization.json",
    ] {
        let contract = std::fs::read(fixture_path(name)).expect(name);
        let apple = std::fs::read(apple_fixture_path(name)).expect(name);
        assert_eq!(
            contract, apple,
            "{name} differs between contracts/fixtures and the Apple test bundle"
        );
    }
}

/// Rebuild every vector's canonical bytes and digest as the Apple tests do.
#[test]
fn the_runtime_rebuilds_every_committed_vector() {
    let text = std::fs::read_to_string(fixture_path("request-signing-fuzz.json")).unwrap();
    let document: Value = serde_json::from_str(&text).unwrap();
    let cases = document["cases"].as_array().unwrap();
    assert_eq!(cases.len(), VECTOR_CASES);
    for case in cases {
        let request = &case["request"];
        let digest = sha256_hex(request["body"].as_str().unwrap().as_bytes());
        assert_eq!(digest, case["content_sha256"].as_str().unwrap());
        let produced = canonical(
            request["method"].as_str().unwrap(),
            request["path_and_query"].as_str().unwrap(),
            request["timestamp"].as_str().unwrap(),
            request["nonce"].as_str().unwrap(),
            &digest,
            &uuid::Uuid::parse_str(request["device_id"].as_str().unwrap()).unwrap(),
            &SIGNING_NODE_ID,
        );
        assert_eq!(
            produced,
            case["canonical"].as_str().unwrap(),
            "{}: canonical bytes differ",
            case["name"]
        );
        assert_eq!(
            sha256_hex(produced.as_bytes()),
            case["canonical_sha256"].as_str().unwrap()
        );
        assert_eq!(produced.lines().count(), 8, "the form has eight lines");
    }
}

/// Two different requests must never sign the same bytes.
#[test]
fn no_two_distinct_requests_share_canonical_bytes() {
    let mut rng = Lcg::new(PROPERTY_SEED);
    let mut seen: HashSet<String> = HashSet::with_capacity(PROPERTY_CASES);
    let mut identities: HashSet<String> = HashSet::with_capacity(PROPERTY_CASES);
    for index in 0..PROPERTY_CASES {
        let request = Request::generate(&mut rng);
        // The tuple as the middleware sees it, method already upper-cased.
        let identity = format!(
            "{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}\u{1f}{}",
            request.method.to_uppercase(),
            request.path_and_query,
            request.timestamp,
            request.nonce,
            request.digest(),
            request.device_id
        );
        let canonical = request.canonical();
        let fresh_identity = identities.insert(identity);
        let fresh_canonical = seen.insert(canonical);
        assert_eq!(
            fresh_identity, fresh_canonical,
            "case {index} broke the one-to-one relation between requests and canonical bytes"
        );
    }
    assert!(
        seen.len() > PROPERTY_CASES / 2,
        "the generator produced too few distinct requests to prove anything"
    );
}

/// Changing any signed field must change canonical bytes and invalidate the original signature.
#[test]
fn one_changed_field_changes_the_canonical_bytes_and_the_signature() {
    let mut rng = Lcg::new(PROPERTY_SEED ^ 0x5155_5441_5449_4F4E);
    let key = p256::ecdsa::SigningKey::from_slice(&[
        0x2f, 0x88, 0x19, 0xc4, 0x7a, 0x35, 0xe0, 0x6b, 0x91, 0x24, 0xdd, 0x53, 0x08, 0xa7, 0x6c,
        0x1e, 0xb3, 0x40, 0x9f, 0x72, 0x58, 0xce, 0x11, 0x86, 0x3a, 0xf5, 0x27, 0x94, 0x6d, 0x0b,
        0xe2, 0x31,
    ])
    .unwrap();
    let verifying = key.verifying_key();
    for index in 0..256 {
        let original = Request::generate(&mut rng);
        let bytes = original.canonical();
        let signature: p256::ecdsa::Signature = key.sign(bytes.as_bytes());
        assert!(verifying.verify(bytes.as_bytes(), &signature).is_ok());

        // One field at a time, leaving the rest exactly as they were.
        let mut mutated = Request::generate(&mut rng);
        for field in 0..6 {
            let mut candidate = Request {
                method: original.method.clone(),
                path_and_query: original.path_and_query.clone(),
                timestamp: original.timestamp.clone(),
                nonce: original.nonce.clone(),
                device_id: original.device_id,
                body: original.body.clone(),
            };
            match field {
                0 if mutated.method.eq_ignore_ascii_case(&original.method) => continue,
                0 => candidate.method = mutated.method.clone(),
                1 if mutated.path_and_query == original.path_and_query => continue,
                1 => candidate.path_and_query = mutated.path_and_query.clone(),
                2 if mutated.timestamp == original.timestamp => continue,
                2 => candidate.timestamp = mutated.timestamp.clone(),
                3 if mutated.nonce == original.nonce => continue,
                3 => candidate.nonce = mutated.nonce.clone(),
                4 if mutated.device_id == original.device_id => continue,
                4 => candidate.device_id = mutated.device_id,
                _ if mutated.body == original.body => continue,
                _ => candidate.body = mutated.body.clone(),
            }
            let changed = candidate.canonical();
            assert_ne!(
                bytes, changed,
                "case {index}: changing field {field} left the signed bytes alone"
            );
            assert!(
                verifying.verify(changed.as_bytes(), &signature).is_err(),
                "case {index}: the original signature still verified after field {field} changed"
            );
            mutated = Request::generate(&mut rng);
        }
    }
}

/// Prove legal HTTP header/URI fields cannot contain canonical delimiters by requiring construction or decoding refusal.
#[test]
fn no_protocol_legal_field_can_contain_the_delimiter() {
    let mut rng = Lcg::new(PROPERTY_SEED ^ 0x4445_4C49_4D49_5445);
    let mut rejected_headers = 0usize;
    let mut rejected_uris = 0usize;
    for _ in 0..PROPERTY_CASES {
        // Overrepresent delimiters so the rejection property receives substantial coverage.
        let length = 1 + rng.below(48);
        let mut candidate = rng.bytes(length);
        let at = rng.below(candidate.len());
        candidate[at] = *rng.pick(&[&b'\n', &b'\r', &b'\t', &b'a', &0u8]);

        match HeaderValue::from_bytes(&candidate) {
            Ok(value) => match value.to_str() {
                Ok(text) => assert!(
                    !text.contains('\n') && !text.contains('\r'),
                    "a header value the middleware would read carried a delimiter: {text:?}"
                ),
                Err(_) => rejected_headers += 1,
            },
            Err(_) => rejected_headers += 1,
        }

        let path = format!("/api/v1/{}", String::from_utf8_lossy(&candidate));
        match Uri::try_from(path.as_str()) {
            Ok(uri) => {
                let assembled = match uri.query() {
                    Some(query) => format!("{}?{query}", uri.path()),
                    None => uri.path().to_owned(),
                };
                assert!(
                    !assembled.contains('\n') && !assembled.contains('\r'),
                    "a parsed URI carried a delimiter: {assembled:?}"
                );
            }
            Err(_) => rejected_uris += 1,
        }
    }
    // Require rejected headers and URIs so a generator omitting delimiters cannot pass vacuously.
    assert!(
        rejected_headers > 0 && rejected_uris > 0,
        "the corpus never produced a field HTTP refuses ({rejected_headers} headers, \
         {rejected_uris} URIs)"
    );
}

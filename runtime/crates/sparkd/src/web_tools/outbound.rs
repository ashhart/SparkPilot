//! Refuse recognised private data before web requests; pattern checks cannot prove arbitrary text contains no private information.

mod normalise;
mod numbers;

/// Longest address the Spark will ask for.
pub const MAX_URL_LENGTH: usize = 2_048;
/// Longest question the Spark will ask a search service.
pub const MAX_QUERY_LENGTH: usize = 400;
/// One code for every class, because the owner's fix is the same: take it out and ask again.
pub const BLOCKED_CODE: &str = "WEB_OUTBOUND_BLOCKED";
/// A node name shorter than this, or one on the stop list, names too many other things to refuse on.
const MIN_DISTINCTIVE_NAME: usize = 5;

/// What was recognised in text that was about to leave the Spark.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Finding {
    EmailAddress,
    PhoneNumber,
    PaymentCard,
    Secret,
    Identifier,
    /// Encoded so many times over that what it carries was never legible.
    Obscured,
    TooLong,
}

impl Finding {
    /// Named in the run's tool list so the owner sees which class stopped the call.
    pub fn kind(self) -> &'static str {
        match self {
            Finding::EmailAddress => "email address",
            Finding::PhoneNumber => "phone number",
            Finding::PaymentCard => "payment card number",
            Finding::Secret => "key or token",
            Finding::Identifier => "device or node identifier",
            Finding::Obscured => "text that stayed encoded",
            Finding::TooLong => "over-long request",
        }
    }

    pub fn explanation(self) -> &'static str {
        match self {
            Finding::TooLong => "That request was too long to send, so nothing was sent.",
            Finding::Obscured => {
                "That request was encoded over and over, so what it carried could not be checked and nothing was sent."
            }
            _ => "That would have sent something private out of the house, so nothing was sent.",
        }
    }
}

/// The names this Spark answers to, so its own identity counts as an identifier.
#[derive(Debug, Clone, Default)]
pub struct OwnNames {
    pub node_id: String,
    pub hostname: String,
}

/// Ordinary words an owner names a Spark, which carry no identifying power of their own.
const ORDINARY_NAMES: &[&str] = &[
    "spark",
    "home",
    "house",
    "desk",
    "study",
    "office",
    "lab",
    "studio",
    "garage",
    "kitchen",
    "living",
    "lounge",
    "room",
    "bedroom",
    "hall",
    "hallway",
    "attic",
    "loft",
    "basement",
    "cellar",
    "shed",
    "den",
    "mini",
    "pro",
    "max",
    "box",
    "server",
    "node",
    "host",
    "machine",
    "computer",
    "tower",
    "rack",
    "cluster",
    "main",
    "work",
    "family",
    "upstairs",
    "downstairs",
];

/// How much of the text is treated as free-form. A URL path carries article ids that a question never would.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reading {
    /// A question, a query string or a fragment: every class applies.
    Free,
    /// A URL path: an article id is not a telephone number, but an encoded payload is still a payload.
    Path,
    /// A host name, where a long mixed-case label is a payload rather than a name.
    Host,
}

impl Reading {
    /// The shortest run that reads as a payload, and the characters that can join one.
    fn entropy(self) -> (usize, &'static str) {
        match self {
            Reading::Free => (32, "-_+/="),
            Reading::Path => (32, "-_+="),
            Reading::Host => (16, "-_"),
        }
    }
}

/// Scan the exact text that would be sent to a search service.
pub fn scan_query(query: &str, own: &OwnNames) -> Option<Finding> {
    if query.chars().count() > MAX_QUERY_LENGTH {
        return Some(Finding::TooLong);
    }
    scan(query, own, Reading::Free)
}

/// Scan an address before it is opened; the host and the path are read as closely as the question is.
pub fn scan_url(url: &str, own: &OwnNames) -> Option<Finding> {
    if url.len() > MAX_URL_LENGTH {
        return Some(Finding::TooLong);
    }
    let (before_fragment, fragment) = split_once(url, '#');
    let (location, query) = split_once(before_fragment, '?');
    let (authority, path) = split_authority(location);
    scan(authority, own, Reading::Host)
        .or_else(|| scan(path, own, Reading::Path))
        .or_else(|| scan(query, own, Reading::Free))
        .or_else(|| scan(fragment, own, Reading::Free))
}

fn split_once(text: &str, separator: char) -> (&str, &str) {
    match text.split_once(separator) {
        Some((head, tail)) => (head, tail),
        None => (text, ""),
    }
}

/// The host part and the path part, whether or not the address carries a scheme.
fn split_authority(location: &str) -> (&str, &str) {
    let after_scheme = match location.find("://") {
        Some(at) => &location[at + 3..],
        None => location,
    };
    match after_scheme.find('/') {
        Some(at) => (&after_scheme[..at], &after_scheme[at..]),
        None => (after_scheme, ""),
    }
}

fn scan(text: &str, own: &OwnNames, reading: Reading) -> Option<Finding> {
    if text.is_empty() {
        return None;
    }
    let canonical = normalise::canonical(text);
    if canonical.still_encoded {
        return Some(Finding::Obscured);
    }
    for candidate in [text, canonical.text.as_str()] {
        if let Some(finding) = scan_once(candidate, own, reading) {
            return Some(finding);
        }
    }
    None
}

fn scan_once(text: &str, own: &OwnNames, reading: Reading) -> Option<Finding> {
    if names_itself(text, own) {
        return Some(Finding::Identifier);
    }
    if has_uuid(text) {
        return Some(Finding::Identifier);
    }
    if has_email(text) {
        return Some(Finding::EmailAddress);
    }
    if let Some(finding) = numbers::scan(text, reading) {
        return Some(finding);
    }
    if has_known_secret(text) {
        return Some(Finding::Secret);
    }
    let (minimum, joiners) = reading.entropy();
    if has_high_entropy_token(text, minimum, joiners) {
        return Some(Finding::Secret);
    }
    None
}

/// The node id always identifies this Spark; its name only does when the name is its own.
fn names_itself(text: &str, own: &OwnNames) -> bool {
    let lowered = text.to_lowercase();
    let node = own.node_id.trim().to_lowercase();
    if node.len() >= 8 && lowered.contains(&node) {
        return true;
    }
    let host = own.hostname.trim().to_lowercase();
    is_distinctive(&host) && contains_word(&lowered, &host)
}

/// A name the owner shares with half the language identifies nobody, and refusing on it breaks search.
fn is_distinctive(name: &str) -> bool {
    name.chars().count() >= MIN_DISTINCTIVE_NAME && !ORDINARY_NAMES.contains(&name)
}

/// A whole word, so a Spark called "Spark" does not refuse "sparkling water".
fn contains_word(haystack: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    haystack.match_indices(needle).any(|(at, _)| {
        let before = haystack[..at].chars().next_back();
        let after = haystack[at + needle.len()..].chars().next();
        before.is_none_or(|c| !c.is_alphanumeric()) && after.is_none_or(|c| !c.is_alphanumeric())
    })
}

/// A UUID in either its dashed or its bare hexadecimal form.
fn has_uuid(text: &str) -> bool {
    for run in runs(text, |character| {
        character.is_ascii_hexdigit() || character == '-'
    }) {
        let bare: String = run.chars().filter(|c| *c != '-').collect();
        if bare.len() == 32 && bare.chars().all(|c| c.is_ascii_hexdigit()) {
            let dashes = run.matches('-').count();
            if dashes == 0 || (dashes == 4 && dashed_uuid(run)) {
                return true;
            }
        }
    }
    false
}

fn dashed_uuid(run: &str) -> bool {
    let parts: Vec<&str> = run.split('-').collect();
    parts.len() == 5
        && [8, 4, 4, 4, 12]
            == [
                parts[0].len(),
                parts[1].len(),
                parts[2].len(),
                parts[3].len(),
                parts[4].len(),
            ]
}

fn has_email(text: &str) -> bool {
    for (index, _) in text.match_indices('@') {
        let local = text[..index]
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_alphanumeric() || "._%+-".contains(*c))
            .count();
        let domain: String = text[index + 1..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
            .collect();
        let tail = domain.rsplit('.').next().unwrap_or_default();
        if local >= 1
            && domain.contains('.')
            && tail.len() >= 2
            && tail.chars().all(|c| c.is_ascii_alphabetic())
        {
            return true;
        }
    }
    false
}

/// Prefixes that are only ever a credential, whatever follows them.
const SECRET_PREFIXES: &[&str] = &[
    "sk-",
    "sk_live_",
    "sk_test_",
    "pk_live_",
    "rk_live_",
    "ghp_",
    "gho_",
    "ghs_",
    "ghu_",
    "github_pat_",
    "xoxb-",
    "xoxp-",
    "xoxa-",
    "xoxs-",
    "AKIA",
    "ASIA",
    "AIza",
    "ya29.",
    "eyJ",
    "-----BEGIN",
    "hf_",
    "glpat-",
    "npm_",
];

fn has_known_secret(text: &str) -> bool {
    for prefix in SECRET_PREFIXES {
        let mut rest = text;
        while let Some(at) = rest.find(prefix) {
            let tail = &rest[at + prefix.len()..];
            let credential = tail
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || "-_.".contains(*c))
                .count();
            if credential >= 12 || *prefix == "-----BEGIN" {
                return true;
            }
            rest = &rest[at + prefix.len()..];
        }
    }
    false
}

/// A long token that mixes cases and digits is a key far more often than it is a word.
fn has_high_entropy_token(text: &str, minimum: usize, joiners: &str) -> bool {
    runs(text, |character| {
        character.is_ascii_alphanumeric() || joiners.contains(character)
    })
    .into_iter()
    .any(|run| {
        run.len() >= minimum
            && run.chars().any(|c| c.is_ascii_digit())
            && run.chars().any(|c| c.is_ascii_lowercase())
            && run.chars().any(|c| c.is_ascii_uppercase())
    })
}

/// Split into maximal runs of characters the predicate accepts.
fn runs(text: &str, accept: impl Fn(char) -> bool) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = None;
    for (index, character) in text.char_indices() {
        match (accept(character), start) {
            (true, None) => start = Some(index),
            (false, Some(from)) => {
                out.push(text[from..index].trim());
                start = None;
            }
            _ => {}
        }
    }
    if let Some(from) = start {
        out.push(text[from..].trim());
    }
    out.into_iter().filter(|run| !run.is_empty()).collect()
}

#[cfg(test)]
#[path = "outbound/tests.rs"]
mod tests;

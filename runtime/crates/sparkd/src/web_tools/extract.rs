//! Turn a fetched page into plain readable text, dropping everything that is markup rather than reading.

/// Elements whose contents are never reading matter.
const DROPPED: &[&str] = &["script", "style", "noscript", "svg", "template", "iframe"];

/// Elements that end a line of reading.
const BLOCKS: &[&str] = &[
    "p",
    "div",
    "br",
    "li",
    "tr",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "section",
    "article",
    "header",
    "footer",
    "blockquote",
    "pre",
    "td",
    "th",
    "ul",
    "ol",
    "table",
    "nav",
    "main",
];

/// What a fetched page contributes to the model's turn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Readable {
    pub title: Option<String>,
    pub text: String,
}

/// Extract a title and the readable text, stopping at `limit` characters.
pub fn readable(html: &str, limit: usize) -> Readable {
    Readable {
        title: title(html),
        text: truncate(&text(html), limit),
    }
}

/// Plain text is passed through with its whitespace collapsed.
pub fn readable_text(body: &str, limit: usize) -> Readable {
    Readable {
        title: None,
        text: truncate(&collapse(body), limit),
    }
}

/// Neutralise any quoting delimiter the content spells out, so a page cannot close its own block.
pub fn neutralise_delimiters(text: &str) -> String {
    let lower = text.to_ascii_lowercase();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while let Some(found) = lower[index..].find('<') {
        let at = index + found;
        out.push_str(&text[index..at]);
        let rest = &lower[at + 1..];
        let name = rest.strip_prefix('/').unwrap_or(rest);
        if name.starts_with("untrusted") {
            out.push_str("&lt;");
        } else {
            out.push('<');
        }
        index = at + 1;
    }
    out.push_str(&text[index..]);
    out
}

fn title(html: &str) -> Option<String> {
    let lower = html.to_ascii_lowercase();
    let open = lower.find("<title")?;
    let start = lower[open..].find('>')? + open + 1;
    let end = lower[start..].find("</title>")? + start;
    let value = decode_entities(&collapse(&html[start..end]));
    (!value.is_empty()).then(|| truncate(&value, 300))
}

fn text(html: &str) -> String {
    let bytes: Vec<char> = html.chars().collect();
    let mut out = String::with_capacity(html.len() / 2);
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != '<' {
            out.push(bytes[index]);
            index += 1;
            continue;
        }
        if starts_with(&bytes, index, "<!--") {
            index = find(&bytes, index + 4, "-->").map_or(bytes.len(), |at| at + 3);
            continue;
        }
        let Some(close) = bytes[index..]
            .iter()
            .position(|c| *c == '>')
            .map(|at| at + index)
        else {
            break;
        };
        let tag: String = bytes[index + 1..close].iter().collect();
        let name = tag_name(&tag);
        if DROPPED.contains(&name.as_str()) && !tag.starts_with('/') {
            let closing = format!("</{name}");
            index = find(&bytes, close, &closing)
                .and_then(|at| {
                    bytes[at..]
                        .iter()
                        .position(|c| *c == '>')
                        .map(|end| at + end + 1)
                })
                .unwrap_or(bytes.len());
            continue;
        }
        if BLOCKS.contains(&name.as_str()) {
            out.push('\n');
        } else {
            out.push(' ');
        }
        index = close + 1;
    }
    collapse_lines(&decode_entities(&out))
}

fn tag_name(tag: &str) -> String {
    tag.trim_start_matches('/')
        .split(|c: char| c.is_whitespace() || c == '/' || c == '>')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase()
}

fn starts_with(chars: &[char], at: usize, needle: &str) -> bool {
    needle
        .chars()
        .enumerate()
        .all(|(offset, expected)| chars.get(at + offset) == Some(&expected))
}

fn find(chars: &[char], from: usize, needle: &str) -> Option<usize> {
    (from..chars.len()).find(|at| starts_with(chars, *at, needle))
}

/// Collapse runs of whitespace to one space and drop the rest.
fn collapse(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Keep paragraph breaks while removing the blank space markup leaves behind.
fn collapse_lines(value: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    for line in value.split('\n') {
        let trimmed = collapse(line);
        if trimmed.is_empty() {
            continue;
        }
        lines.push(trimmed);
    }
    lines.join("\n")
}

fn decode_entities(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let Some(end) = tail[..tail.len().min(12)].find(';') else {
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        let entity = &tail[1..end];
        match named(entity) {
            Some(text) => out.push_str(text),
            None => match numeric(entity) {
                Some(character) => out.push(character),
                None => {
                    out.push('&');
                    out.push_str(entity);
                    out.push(';');
                }
            },
        }
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    out
}

fn named(entity: &str) -> Option<&'static str> {
    Some(match entity {
        "amp" => "&",
        "lt" => "<",
        "gt" => ">",
        "quot" => "\"",
        "apos" | "#39" => "'",
        "nbsp" => " ",
        "hellip" => "…",
        "mdash" => "—",
        "ndash" => "–",
        "rsquo" | "#8217" => "\u{2019}",
        "lsquo" => "\u{2018}",
        "ldquo" => "\u{201c}",
        "rdquo" => "\u{201d}",
        _ => return None,
    })
}

fn numeric(entity: &str) -> Option<char> {
    let digits = entity.strip_prefix('#')?;
    let value = match digits
        .strip_prefix('x')
        .or_else(|| digits.strip_prefix('X'))
    {
        Some(hex) => u32::from_str_radix(hex, 16).ok()?,
        None => digits.parse().ok()?,
    };
    char::from_u32(value)
}

/// Cut on a character boundary and say so, so the model never sees a silent truncation.
fn truncate(value: &str, limit: usize) -> String {
    if value.chars().count() <= limit {
        return value.to_owned();
    }
    let mut out: String = value.chars().take(limit).collect();
    out.push_str("\n[truncated]");
    out
}

#[cfg(test)]
#[path = "extract/tests.rs"]
mod tests;

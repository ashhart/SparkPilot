//! The owner's calendar and reminders never reach the tool loop, whatever part of the transcript carried them.

use serde_json::Value;

/// The tags the app wraps the owner's calendar and reminders in, declared in `SparkChatPersonalSummary.swift`.
pub const OPENING_TAG: &str = "<personal_context>";
pub const CLOSING_TAG: &str = "</personal_context>";

/// Take every personal-context block out of the system turn and out of every message.
pub fn without_personal_context(
    instruction: Option<&str>,
    conversation: Vec<Value>,
) -> (Option<String>, Vec<Value>, bool) {
    let mut stripped = false;
    let instruction = instruction.map(|value| match strip(value) {
        Some(clean) => {
            stripped = true;
            clean
        }
        None => value.to_owned(),
    });
    let conversation = conversation
        .into_iter()
        .map(|turn| strip_value(turn, &mut stripped))
        .collect();
    (instruction, conversation, stripped)
}

/// Every string in a message, so a content array carries no more than a plain content string does.
fn strip_value(value: Value, stripped: &mut bool) -> Value {
    match value {
        Value::String(text) => match strip(&text) {
            Some(clean) => {
                *stripped = true;
                Value::String(clean)
            }
            None => Value::String(text),
        },
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| strip_value(item, stripped))
                .collect(),
        ),
        Value::Object(fields) => Value::Object(
            fields
                .into_iter()
                .map(|(key, item)| (key, strip_value(item, stripped)))
                .collect(),
        ),
        other => other,
    }
}

/// Everything from an opening tag to its closing tag; an unclosed block takes the rest of the turn with it.
fn strip(text: &str) -> Option<String> {
    if !text.contains(OPENING_TAG) {
        return None;
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find(OPENING_TAG) {
        out.push_str(&rest[..at]);
        let after = &rest[at + OPENING_TAG.len()..];
        match after.find(CLOSING_TAG) {
            Some(end) => rest = &after[end + CLOSING_TAG.len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    Some(out)
}

#[cfg(test)]
#[path = "redact/tests.rs"]
mod tests;

//! Project log tails to allowlisted runtime fields or leading engine timestamp and severity, never raw text.

use std::time::Duration;

use serde_json::{Value, json};
use spark_privd::protocol::{LogSource, MAX_DIAGNOSTIC_LOG_LINES, PrivilegedOperation};

use super::collect::read_row;
use super::{NO_ACTIVE_ENGINE, NO_PRIVILEGED_BOUNDARY};
use crate::state::AppState;

/// One log tail must not hold the export open.
const LOG_TIMEOUT: Duration = Duration::from_secs(3);

const LOG_UNAVAILABLE: &str = "LOG_UNAVAILABLE";

pub(super) async fn logs_section(state: &AppState) -> Value {
    let mut sources = vec![
        log_tail(state, LogSource::Sparkd).await,
        log_tail(state, LogSource::SparkPrivd).await,
    ];
    sources.push(match active_instance_id(state) {
        Some(instance_id) => log_tail(state, LogSource::Engine { instance_id }).await,
        None => json!({ "source": "engine", "available": false, "reason_code": NO_ACTIVE_ENGINE }),
    });

    json!({
        "available": true,
        "max_lines": MAX_DIAGNOSTIC_LOG_LINES,
        "sources": sources,
        "operation_stages": super::collect::operation_stages_section(state),
    })
}

fn active_instance_id(state: &AppState) -> Option<uuid::Uuid> {
    read_row(
        state,
        "SELECT id FROM inference_instances WHERE state != 'stopped' \
         ORDER BY started_at DESC LIMIT 1",
        |row| row.get::<_, String>(0).map(Value::from),
    )
    .and_then(|value| value.as_str().and_then(|id| uuid::Uuid::parse_str(id).ok()))
}

/// Read bounded privileged logs and report fixed error codes without path-bearing helper failure text.
async fn log_tail(state: &AppState, source: LogSource) -> Value {
    let Some(privileged) = state.privileged.clone() else {
        return json!({
            "source": source.name(),
            "available": false,
            "reason_code": NO_PRIVILEGED_BOUNDARY,
        });
    };
    let response = tokio::task::spawn_blocking(move || {
        privileged.call_bounded(
            PrivilegedOperation::ReadDiagnosticLog {
                request_id: uuid::Uuid::new_v4(),
                source,
                max_lines: MAX_DIAGNOSTIC_LOG_LINES,
            },
            LOG_TIMEOUT,
        )
    })
    .await;

    match response {
        Ok(Ok(response)) if response.accepted => {
            let raw = response
                .details
                .get("lines")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let records: Vec<Value> = raw
                .iter()
                .filter_map(Value::as_str)
                .map(|line| project_line(source, line))
                .collect();
            json!({
                "source": source.name(),
                "available": true,
                "truncated": response.details.get("truncated").cloned().unwrap_or(json!(false)),
                "lines_observed": raw.len(),
                "records": records,
            })
        }
        Ok(Ok(_)) => json!({
            "source": source.name(),
            "available": false,
            "reason_code": LOG_UNAVAILABLE,
        }),
        // Use fixed failure codes in both bundle and logs; helper errors and panic payloads may disclose paths or content.
        Ok(Err(_)) => {
            tracing::warn!(source = source.name(), "diagnostic log tail failed");
            json!({
                "source": source.name(),
                "available": false,
                "reason_code": LOG_UNAVAILABLE,
            })
        }
        Err(_) => {
            tracing::error!(source = source.name(), "diagnostic log task failed");
            json!({
                "source": source.name(),
                "available": false,
                "reason_code": LOG_UNAVAILABLE,
            })
        }
    }
}

/// Validate both field names and value shapes; rejecting invalid values prevents free text from escaping through allowed keys.
enum FieldShape {
    /// Parse and reformat RFC 3339 timestamps instead of copying raw text.
    Timestamp,
    /// One of a closed set.
    OneOf(&'static [&'static str]),
    /// A UUID.
    Uuid,
    /// Exactly 64 lowercase hex characters.
    Sha256Hex,
    /// A short token from `charset`, at most `max` characters.
    Token {
        charset: fn(char) -> bool,
        max: usize,
    },
}

/// Allowlist shaped log fields while excluding tracing message and span fields that can carry free text.
const STRUCTURED_LOG_FIELDS: &[(&str, FieldShape)] = &[
    ("timestamp", FieldShape::Timestamp),
    (
        "level",
        FieldShape::OneOf(&["TRACE", "DEBUG", "INFO", "WARN", "ERROR"]),
    ),
    ("service", FieldShape::OneOf(&["sparkd", "spark-privd"])),
    (
        "target",
        FieldShape::Token {
            charset: is_module_path_character,
            max: 64,
        },
    ),
    ("request_id", FieldShape::Uuid),
    ("operation_id", FieldShape::Uuid),
    ("device_id_hash", FieldShape::Sha256Hex),
    (
        "event",
        FieldShape::Token {
            charset: is_event_name_character,
            max: 64,
        },
    ),
    (
        "model_id",
        FieldShape::Token {
            charset: is_model_id_character,
            max: 128,
        },
    ),
    (
        "profile_id",
        FieldShape::Token {
            charset: is_profile_id_character,
            max: 64,
        },
    ),
];

fn is_module_path_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | ':' | '.' | '-')
}

fn is_event_name_character(character: char) -> bool {
    character.is_ascii_lowercase() || character.is_ascii_digit() || matches!(character, '.' | '_')
}

fn is_model_id_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '/' | '-')
}

fn is_profile_id_character(character: char) -> bool {
    character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
}

/// Keep `value` only if it has `shape`.
fn shaped(value: &Value, shape: &FieldShape) -> Option<Value> {
    let candidate = value.as_str()?;
    match shape {
        FieldShape::Timestamp => rfc3339(candidate).map(Value::from),
        FieldShape::OneOf(allowed) => allowed
            .iter()
            .find(|permitted| **permitted == candidate)
            .map(|permitted| Value::from(*permitted)),
        FieldShape::Uuid => uuid::Uuid::parse_str(candidate)
            .ok()
            .map(|parsed| Value::from(parsed.to_string())),
        FieldShape::Sha256Hex => (candidate.len() == 64
            && candidate
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)))
        .then(|| Value::from(candidate)),
        FieldShape::Token { charset, max } => (!candidate.is_empty()
            && candidate.chars().count() <= *max
            && candidate.chars().all(charset))
        .then(|| Value::from(candidate)),
    }
}

/// Parse and reformat timestamps so exported text is runtime-generated.
fn rfc3339(candidate: &str) -> Option<String> {
    time::OffsetDateTime::parse(candidate, &time::format_description::well_known::Rfc3339)
        .ok()?
        .format(&time::format_description::well_known::Rfc3339)
        .ok()
}

/// Accept only complete severity tokens without trailing engine text.
const ENGINE_SEVERITIES: &[&str] = &[
    "TRACE", "DEBUG", "INFO", "NOTICE", "WARN", "WARNING", "ERROR", "CRITICAL", "FATAL",
];

/// Project one raw log line to what may leave the node.
fn project_line(source: LogSource, line: &str) -> Value {
    match source {
        LogSource::Sparkd | LogSource::SparkPrivd => project_structured_line(line),
        LogSource::Engine { .. } => project_engine_line(line),
    }
}

/// Keep only allowlisted structured runtime fields, including when later versions add new keys.
fn project_structured_line(line: &str) -> Value {
    let Ok(Value::Object(parsed)) = serde_json::from_str::<Value>(line) else {
        // Record only the existence of unstructured lines, never their panic or dependency text.
        return json!({ "parsed": false, "redacted": true });
    };
    let mut projected = serde_json::Map::new();
    for (field, shape) in STRUCTURED_LOG_FIELDS {
        if let Some(value) = parsed.get(*field)
            && let Some(kept) = shaped(value, shape)
        {
            projected.insert((*field).to_owned(), kept);
        }
    }
    projected.insert("parsed".into(), json!(true));
    projected.insert("redacted".into(), json!(true));
    Value::Object(projected)
}

/// Keep only leading timestamp and severity from engine output; substring searches could match words inside prompts.
fn project_engine_line(line: &str) -> Value {
    let mut tokens = line.split_whitespace();
    let first = tokens.next().unwrap_or_default();
    let second = tokens.next().unwrap_or_default();

    // Parse complete RFC 3339 timestamps and emit their normalized representation.
    let timestamp = rfc3339(first.trim_end_matches(':'));

    let severity = [first, second]
        .into_iter()
        .map(|token| token.trim_matches(|c: char| !c.is_ascii_alphabetic()))
        .find_map(|token| {
            ENGINE_SEVERITIES
                .iter()
                .find(|severity| token.eq_ignore_ascii_case(severity))
                .copied()
        });

    json!({
        "timestamp": timestamp,
        "severity": severity,
        "redacted": true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_structured_line_contributes_only_allowlisted_fields() {
        let line = serde_json::json!({
            "timestamp": "2026-09-01T00:00:00.000Z",
            "level": "INFO",
            "service": "sparkd",
            "event": "model.load.started",
            "model_id": "acme/model",
            "message": "user asked about the cabin in Vermont",
            "fields": { "message": "user asked about the cabin in Vermont" },
            "spans": [{ "prompt": "user asked about the cabin in Vermont" }],
            "some_future_field": "user asked about the cabin in Vermont",
        })
        .to_string();
        let projected = project_structured_line(&line);
        let rendered = projected.to_string();
        assert!(!rendered.contains("Vermont"), "{rendered}");
        assert_eq!(projected["event"], "model.load.started");
        assert_eq!(projected["level"], "INFO");
        assert_eq!(projected["redacted"], true);
        assert!(projected.get("message").is_none());
        assert!(projected.get("some_future_field").is_none());
    }

    #[test]
    fn an_allowlisted_field_holding_free_text_is_dropped_not_trimmed() {
        // Every field a writer could put a sentence in, holding one.
        let prompt = "summarise the letter my sister sent about the house";
        let line = serde_json::json!({
            "timestamp": prompt,
            "level": prompt,
            "service": prompt,
            "target": prompt,
            "request_id": prompt,
            "operation_id": prompt,
            "device_id_hash": prompt,
            "event": prompt,
            "model_id": prompt,
            "profile_id": prompt,
        })
        .to_string();
        let projected = project_structured_line(&line);
        assert!(!projected.to_string().contains("sister"), "{projected}");
        assert_eq!(projected, json!({ "parsed": true, "redacted": true }));
    }

    #[test]
    fn a_well_shaped_field_survives_in_the_runtime_s_own_spelling() {
        let line = serde_json::json!({
            "timestamp": "2026-09-01T00:00:00Z",
            "level": "WARN",
            "service": "sparkd",
            "target": "sparkd::engine",
            "operation_id": "8C55AC55-38C1-43CF-B123-8E546F80A66E",
            "event": "model.load.started",
            "profile_id": "balanced-16k",
        })
        .to_string();
        let projected = project_structured_line(&line);
        assert_eq!(projected["level"], "WARN");
        assert_eq!(projected["target"], "sparkd::engine");
        assert_eq!(projected["event"], "model.load.started");
        // Re-emitted from the parsed value, not copied out of the line.
        assert_eq!(
            projected["operation_id"],
            "8c55ac55-38c1-43cf-b123-8e546f80a66e"
        );
    }

    #[test]
    fn an_unparseable_line_contributes_nothing_but_its_existence() {
        let projected = project_structured_line("thread panicked at 'the cabin in Vermont'");
        assert_eq!(projected, json!({ "parsed": false, "redacted": true }));
    }

    #[test]
    fn an_engine_line_keeps_only_a_timestamp_and_a_known_severity() {
        let projected = project_engine_line(
            "2026-09-01T00:00:00Z INFO Received request: draft a note about the cabin",
        );
        assert_eq!(projected["timestamp"], "2026-09-01T00:00:00Z");
        assert_eq!(projected["severity"], "INFO");
        assert_eq!(projected["redacted"], true);
        assert!(!projected.to_string().contains("cabin"));

        // A line that is nothing but prompt text keeps nothing.
        let bare = project_engine_line("the quiet house by the lake, in three sentences");
        assert_eq!(bare["timestamp"], Value::Null);
        assert_eq!(bare["severity"], Value::Null);
        assert_eq!(bare["redacted"], true);

        // A severity-looking word later in the line is not a severity.
        let late = project_engine_line("please summarise the ERROR my colleague reported");
        assert_eq!(late["severity"], Value::Null);
    }
}

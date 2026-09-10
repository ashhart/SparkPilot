use super::*;

/// Accumulate usage from streaming chunks or buffered completion bodies.
#[derive(Default, Clone)]
pub(crate) struct UsageTotals {
    pub(in crate::engine_api) prompt_tokens: u64,
    pub(crate) completion_tokens: u64,
    pub(in crate::engine_api) total_tokens: u64,
    pub(in crate::engine_api) saw: bool,
    pub(in crate::engine_api) precise_counts: bool,
}

impl UsageTotals {
    pub(crate) fn from_json(value: &Value) -> Option<Self> {
        let usage = value
            .get("usage")
            .or_else(|| {
                value
                    .get("response")
                    .and_then(|response| response.get("usage"))
            })
            .or_else(|| {
                value
                    .get("message")
                    .and_then(|message| message.get("usage"))
            })?;
        let prompt_tokens = usage
            .get("prompt_tokens")
            .or_else(|| usage.get("input_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let completion_tokens = usage
            .get("completion_tokens")
            .or_else(|| usage.get("output_tokens"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let total = usage
            .get("total_tokens")
            .and_then(Value::as_u64)
            .unwrap_or(prompt_tokens.saturating_add(completion_tokens));
        if total == 0 {
            return None;
        }
        let precise_counts = usage
            .get("prompt_tokens")
            .or_else(|| usage.get("input_tokens"))
            .and_then(Value::as_u64)
            .is_some()
            && usage
                .get("completion_tokens")
                .or_else(|| usage.get("output_tokens"))
                .and_then(Value::as_u64)
                .is_some()
            && prompt_tokens.checked_add(completion_tokens) == Some(total);
        Some(Self {
            prompt_tokens,
            completion_tokens,
            total_tokens: total,
            saw: true,
            precise_counts,
        })
    }

    /// A deliberately generous stand-in when nothing was reported: four bytes to a token, never fewer than `floor`.
    pub(crate) fn estimate(prompt_bytes: usize, completion_bytes: usize, floor: u64) -> Self {
        let prompt_tokens = (prompt_bytes / 4) as u64;
        let completion_tokens = ((completion_bytes / 4) as u64).max(floor);
        Self {
            prompt_tokens,
            completion_tokens,
            total_tokens: prompt_tokens.saturating_add(completion_tokens),
            saw: false,
            precise_counts: false,
        }
    }

    pub(crate) fn tokens_per_second(&self, ticket: &InferenceRequestTicket) -> Option<f64> {
        if !self.saw || self.total_tokens == 0 {
            return None;
        }
        let secs = ticket.elapsed().unwrap_or(Duration::ZERO).as_secs_f64();
        if secs <= 0.0 {
            return None;
        }
        Some(self.total_tokens as f64 / secs)
    }
}

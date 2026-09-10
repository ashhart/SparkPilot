use super::*;

/// Upper bound on a single upstream frame line scanned for usage.
pub(super) const SCAN_LINE_CAP: usize = 256 * 1024;

mod usage_totals;
pub(crate) use usage_totals::UsageTotals;

/// Attribute daily usage to catalogue model identity and the signed originating device.
#[derive(Clone)]
pub(crate) struct UsageRecorder {
    pub(super) db: Arc<parking_lot::Mutex<rusqlite::Connection>>,
    pub(super) consent: Arc<parking_lot::RwLock<crate::appliance_api::TelemetryConsentConfig>>,
    pub(super) clock: Arc<dyn crate::clock::UtcClock>,
    pub(super) device_id: String,
    pub(super) model_id: String,
    /// Set for a guest, so its budget is accounted whatever the telemetry consent says.
    pub(super) guest: Option<(uuid::Uuid, String)>,
    pub(super) reservation: Option<Arc<crate::guest::budget::Reservation>>,
}

impl UsageRecorder {
    pub(crate) fn new(
        state: &AppState,
        principal: &Principal,
        model_id: &str,
        guest: Option<(uuid::Uuid, String)>,
    ) -> Option<Self> {
        // A guest's budget is a security control, so its counters are kept even when functional telemetry is off.
        if guest.is_none() && !state.telemetry_consent.read().functional {
            return None;
        }
        let db = state.database.as_ref()?;
        Some(Self {
            db: db.clone(),
            consent: state.telemetry_consent.clone(),
            clock: state.clock.clone(),
            device_id: principal.device_id.to_string(),
            model_id: model_id.to_owned(),
            guest,
            reservation: None,
        })
    }

    /// Record one served request whose usage the engine reported.
    pub(crate) fn record_reported(
        &self,
        usage: &UsageTotals,
        ttft: Duration,
        generation: Duration,
    ) {
        self.record(usage, usage, ttft, generation);
    }

    /// Record one served request; `estimate` stands in when the engine reported no usage at all.
    pub(crate) fn record(
        &self,
        usage: &UsageTotals,
        estimate: &UsageTotals,
        ttft: Duration,
        generation: Duration,
    ) {
        let estimated = !usage.saw;
        let charged = if estimated { estimate } else { usage };
        if let Some(reservation) = &self.reservation {
            if usage.precise_counts {
                reservation.settle(usage.prompt_tokens, usage.completion_tokens);
            }
        } else {
            self.record_guest_request(charged, estimated);
        }
        if charged.total_tokens == 0 {
            return;
        }
        let source = spark_telemetry::UsageRecord::request(
            self.device_id.clone(),
            self.model_id.clone(),
            charged.prompt_tokens,
            charged.completion_tokens,
            ttft,
            generation,
        );
        let day = {
            let now = self.clock.now().to_offset(time::UtcOffset::UTC);
            format!(
                "{:04}-{:02}-{:02}",
                now.year(),
                u8::from(now.month()),
                now.day()
            )
        };
        let conn = self.db.lock();
        // Hold live consent through the write so withdrawal also gates streams admitted earlier.
        let consent = self.consent.read();
        if !consent.functional {
            return;
        }
        if let Err(error) = spark_telemetry::record_daily(&conn, &day, &source) {
            tracing::warn!(%error, "failed to record daily usage");
        }
    }

    /// Count one served guest request against the owner's local day, whatever the model reported.
    fn record_guest_request(&self, usage: &UsageTotals, estimated: bool) {
        let Some((device_id, local_day)) = &self.guest else {
            return;
        };
        let conn = self.db.lock();
        if let Err(error) = crate::guest::record_request(
            &conn,
            device_id,
            local_day,
            usage.prompt_tokens,
            usage.completion_tokens,
            &self.clock.now_rfc3339(),
        ) {
            tracing::error!(%error, "guest usage could not be recorded");
        }
        if estimated {
            self.audit_estimate(&conn, device_id, local_day, usage);
        }
    }

    /// Say in the audit trail when a guest's day was charged a stand-in rather than reported counts.
    fn audit_estimate(
        &self,
        conn: &rusqlite::Connection,
        device_id: &uuid::Uuid,
        local_day: &str,
        usage: &UsageTotals,
    ) {
        if let Err(error) = crate::audit::append(
            conn,
            self.clock.as_ref(),
            &crate::audit::AuditDraft {
                actor_device_id: Some(*device_id),
                actor_role: Some("guest"),
                source_route: "/v1",
                action: "guest.usage.estimated",
                resource: Some("shared-access/self"),
                result: "accepted",
                operation_id: None,
                request_id: None,
                details: &serde_json::json!({
                    "local_day": local_day,
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "reason": "the engine reported no usage for this request",
                }),
            },
        ) {
            tracing::error!(%error, "an estimated guest charge could not be audited");
        }
    }
}

/// Forward stream bytes unchanged and account usage; ticket completion or drop releases the request exactly once.
pub(super) struct UsageTee<S> {
    pub(super) frames: S,
    /// Held for the life of the stream so a guest's concurrency slot is released when the stream ends.
    pub(super) guest_slot: Option<crate::guest::GuestSlot>,
    pub(super) ticket: Option<InferenceRequestTicket>,
    pub(super) scanner: UsageScanner,
    pub(super) recorder: Option<UsageRecorder>,
    pub(super) first: bool,
    pub(super) peer_loss_emitted: bool,
    pub(super) attempt: Option<crate::request_history::Attempt>,
    /// Bytes of the body sent upstream, for the stand-in charge when nothing is reported.
    pub(super) prompt_bytes: usize,
    pub(super) completion_bytes: usize,
    pub(super) chunks: u64,
    /// Latency captured before the ticket is taken, so a cancelled stream still records its timing.
    pub(super) timings: Option<(Duration, Duration)>,
}

impl<S> UsageTee<S> {
    fn estimated_usage(&self) -> UsageTotals {
        UsageTotals::estimate(self.prompt_bytes, self.completion_bytes, self.chunks)
    }

    /// Read the ticket's latency once, before any arm takes it.
    fn capture_timings(&mut self) {
        if self.timings.is_some() {
            return;
        }
        let elapsed = self
            .ticket
            .as_ref()
            .and_then(InferenceRequestTicket::elapsed)
            .unwrap_or_default();
        let ttft = Duration::from_secs_f64(
            self.ticket
                .as_ref()
                .and_then(InferenceRequestTicket::ttft_ms)
                .map(|ms| ms / 1000.0)
                .unwrap_or(0.0),
        );
        self.timings = Some((ttft, elapsed.saturating_sub(ttft)));
    }
}

/// Record on every exit, not only clean end of stream: a cancelled or reset stream was still served.
impl<S> Drop for UsageTee<S> {
    fn drop(&mut self) {
        let Some(recorder) = self.recorder.take() else {
            return;
        };
        self.capture_timings();
        let (ttft, generation) = self.timings.unwrap_or_default();
        let estimate = self.estimated_usage();
        let mut usage = self.scanner.usage.clone();
        usage.precise_counts &=
            self.scanner.completed && !self.scanner.failed && self.scanner.saw_output;
        recorder.record(&usage, &estimate, ttft, generation);
    }
}

/// Scan usage with at most one bounded partial line so missing newlines cannot grow stream memory without limit.
#[derive(Default)]
pub struct UsageScanner {
    pub(super) line_buf: Vec<u8>,
    pub(super) usage: UsageTotals,
    /// Discard oversized lines through the next newline so padded tails cannot masquerade as independent usage frames.
    pub(super) discarding: bool,
    pub(super) completed: bool,
    pub(super) saw_output: bool,
    pub(super) failed: bool,
    anthropic_input_tokens: Option<u64>,
    anthropic_stop_reason_valid: bool,
}

impl UsageScanner {
    /// Scan one chunk for complete `data: {json}` SSE lines (usage chunks).
    pub fn scan_frame(&mut self, chunk: &[u8]) {
        for &byte in chunk {
            if matches!(byte, b'\n' | b'\r') {
                let line = std::mem::take(&mut self.line_buf);
                if std::mem::take(&mut self.discarding) {
                    continue;
                }
                self.process_line(&line);
            } else if !self.discarding {
                self.line_buf.push(byte);
                if self.line_buf.len() > SCAN_LINE_CAP {
                    self.line_buf.clear();
                    self.discarding = true;
                }
            }
        }
    }

    /// Bytes held for the line in progress. Never above [`SCAN_LINE_CAP`].
    pub fn buffered(&self) -> usize {
        self.line_buf.len()
    }

    /// Total tokens seen so far, `None` until an upstream frame reported some.
    pub fn total_tokens(&self) -> Option<u64> {
        self.usage.saw.then_some(self.usage.total_tokens)
    }

    fn process_line(&mut self, line: &[u8]) {
        let Some(trimmed) = line.strip_prefix(b"data:") else {
            return;
        };
        let trimmed = trimmed.strip_prefix(b" ").unwrap_or(trimmed);
        if trimmed == b"[DONE]" {
            self.completed = true;
            return;
        }
        if trimmed.is_empty() {
            return;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(trimmed) {
            match value.get("type").and_then(Value::as_str) {
                Some("message_start") => {
                    self.anthropic_input_tokens = value
                        .get("message")
                        .and_then(|v| v.get("usage"))
                        .and_then(|v| v.get("input_tokens"))
                        .and_then(Value::as_u64);
                    self.anthropic_stop_reason_valid = false;
                    if let Some(mut usage) = UsageTotals::from_json(&value) {
                        usage.precise_counts = false;
                        self.usage = usage;
                    }
                }
                Some("message_delta") => {
                    // Native Messages reports input once and cumulative output in a separate frame.
                    if let (Some(input), Some(output)) = (
                        self.anthropic_input_tokens,
                        value
                            .get("usage")
                            .and_then(|v| v.get("output_tokens"))
                            .and_then(Value::as_u64),
                    ) {
                        self.usage = UsageTotals {
                            prompt_tokens: input,
                            completion_tokens: output,
                            total_tokens: input.saturating_add(output),
                            saw: true,
                            precise_counts: input.checked_add(output).is_some(),
                        };
                    }
                    if let Some(reason) = value
                        .get("delta")
                        .and_then(|v| v.get("stop_reason"))
                        .and_then(Value::as_str)
                    {
                        self.anthropic_stop_reason_valid =
                            ["end_turn", "max_tokens", "stop_sequence", "tool_use"]
                                .contains(&reason);
                        self.failed |= !self.anthropic_stop_reason_valid;
                    }
                }
                _ => {
                    if let Some(usage) = UsageTotals::from_json(&value) {
                        self.usage = usage;
                    }
                }
            }
            if value.get("error").is_some_and(|error| !error.is_null()) {
                self.failed = true;
            }
            match value.get("type").and_then(Value::as_str) {
                Some("response.completed") => self.completed = true,
                Some("message_stop") => {
                    self.completed = true;
                    self.failed |= !self.anthropic_stop_reason_valid;
                }
                Some("content_block_start") => {
                    self.saw_output |= value.get("content_block").is_some_and(|block| {
                        block.get("type").and_then(Value::as_str) == Some("tool_use")
                            || ["text", "thinking"].iter().any(|key| {
                                block
                                    .get(*key)
                                    .and_then(Value::as_str)
                                    .is_some_and(|v| !v.is_empty())
                            })
                    });
                }
                Some("content_block_delta") => {
                    self.saw_output |= value.get("delta").is_some_and(|delta| {
                        ["text", "thinking", "partial_json"].iter().any(|key| {
                            delta
                                .get(*key)
                                .and_then(Value::as_str)
                                .is_some_and(|v| !v.is_empty())
                        })
                    });
                }
                Some("response.failed" | "response.incomplete" | "error") => self.failed = true,
                Some("response.output_text.delta" | "response.reasoning_text.delta") => {
                    self.saw_output |= value
                        .get("delta")
                        .and_then(Value::as_str)
                        .is_some_and(|v| !v.is_empty())
                }
                _ => {}
            }
            for choice in value
                .get("choices")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(delta) = choice.get("delta") {
                    for key in ["content", "reasoning_content", "reasoning"] {
                        self.saw_output |= delta
                            .get(key)
                            .and_then(Value::as_str)
                            .is_some_and(|v| !v.is_empty());
                    }
                    self.saw_output |= delta
                        .get("tool_calls")
                        .and_then(Value::as_array)
                        .is_some_and(|v| !v.is_empty());
                }
                if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
                    self.failed |= !["stop", "length", "tool_calls"].contains(&reason);
                }
            }
        }
    }
}

impl<S> UsageTee<S>
where
    S: Stream<Item = Result<Bytes, reqwest::Error>> + Unpin + Send + 'static,
{
    pub(super) fn new(
        frames: S,
        ticket: InferenceRequestTicket,
        recorder: Option<UsageRecorder>,
    ) -> Self {
        Self {
            frames,
            guest_slot: None,
            scanner: UsageScanner::default(),
            ticket: Some(ticket),
            recorder,
            first: true,
            peer_loss_emitted: false,
            attempt: None,
            prompt_bytes: 0,
            completion_bytes: 0,
            chunks: 0,
            timings: None,
        }
    }
}

impl<S> Stream for UsageTee<S>
where
    S: Stream<Item = Result<Bytes, reqwest::Error>> + Unpin + Send + 'static,
    Self: Unpin,
{
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        if self
            .attempt
            .as_mut()
            .is_some_and(|attempt| attempt.poll_cancel(cx).is_ready())
        {
            if let Some(mut attempt) = self.attempt.take() {
                attempt.finish("cancelled_unconfirmed", Some("CALLER_CANCELLED"), None);
            }
            self.capture_timings();
            self.ticket.take();
            self.peer_loss_emitted = true;
            return std::task::Poll::Ready(Some(Err(std::io::Error::new(
                std::io::ErrorKind::Interrupted,
                "request cancelled",
            ))));
        }
        if !self.peer_loss_emitted
            && let Some(ticket) = self.ticket.as_mut()
            && let std::task::Poll::Ready(Some(loss)) = ticket.poll_cluster_failure(cx)
        {
            self.peer_loss_emitted = true;
            let code = loss.request_failure_code();
            // Record the attempt under its real outcome before the caller sees the error frame.
            if let Some(mut attempt) = self.attempt.take() {
                attempt.finish("failed", Some(code), None);
            }
            let payload = serde_json::json!({
                "error": {
                    "code": code,
                    "message": crate::cluster_inference::peer_loss_message(loss),
                }
            });
            self.capture_timings();
            if let Some(mut ticket) = self.ticket.take() {
                ticket.note_complete(None);
            }
            return std::task::Poll::Ready(Some(Ok(Bytes::from(format!(
                "event: error\ndata: {payload}\n\n"
            )))));
        }
        if self.peer_loss_emitted {
            return std::task::Poll::Ready(None);
        }
        match self.frames.poll_next_unpin(cx) {
            std::task::Poll::Ready(Some(Ok(chunk))) => {
                self.scanner.scan_frame(&chunk);
                self.completion_bytes = self.completion_bytes.saturating_add(chunk.len());
                self.chunks = self.chunks.saturating_add(1);
                if let Some(attempt) = &mut self.attempt {
                    attempt.first_frame();
                }
                if self.scanner.completed {
                    let valid = self.scanner.saw_output && !self.scanner.failed;
                    let usage = self.scanner.usage.precise_counts.then_some((
                        self.scanner.usage.prompt_tokens,
                        self.scanner.usage.completion_tokens,
                    ));
                    if let Some(attempt) = &mut self.attempt {
                        attempt.finish(
                            if valid { "succeeded" } else { "incomplete" },
                            if valid {
                                None
                            } else {
                                Some("INVALID_COMPLETION")
                            },
                            usage,
                        );
                    }
                }
                if self.first {
                    self.first = false;
                    if let Some(ticket) = self.ticket.as_mut() {
                        ticket.note_first_frame();
                    }
                }
                std::task::Poll::Ready(Some(Ok(chunk)))
            }
            std::task::Poll::Ready(Some(Err(e))) => {
                if let Some(attempt) = &mut self.attempt {
                    attempt.finish("failed", Some("UPSTREAM_READ_FAILED"), None);
                }
                self.capture_timings();
                if let Some(mut ticket) = self.ticket.take() {
                    ticket.note_complete(None);
                }
                std::task::Poll::Ready(Some(Err(std::io::Error::other(e.to_string()))))
            }
            std::task::Poll::Ready(None) => {
                let usage = self.scanner.usage.precise_counts.then_some((
                    self.scanner.usage.prompt_tokens,
                    self.scanner.usage.completion_tokens,
                ));
                if let Some(attempt) = &mut self.attempt {
                    attempt.finish("incomplete", Some("TERMINAL_MARKER_MISSING"), usage);
                }
                // The recording itself is in Drop, so cancel and peer loss are charged the same way.
                self.capture_timings();
                if let Some(mut ticket) = self.ticket.take() {
                    let tps = self.scanner.usage.tokens_per_second(&ticket);
                    ticket.note_complete(tps);
                }
                std::task::Poll::Ready(None)
            }
            std::task::Poll::Pending => std::task::Poll::Pending,
        }
    }
}

#[cfg(test)]
#[path = "usage_stream_tests.rs"]
mod tests;

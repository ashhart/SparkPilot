//! Spend one run's web budget: what was asked, what was read, what was refused, and when to stop.
use std::collections::HashMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::backend::{self, WebAccessSettings};
use super::guard::{Guard, HostResolver};
use super::ledger::{CallLedger, ProcessLedger};
use super::outbound::{self, OwnNames};
use super::policy::{self, Surface};
use super::robots::Robots;
use crate::clock::UtcClock;
use wording::{refusal_text, render_results, search_explanation, stopped_explanation, truncate};

/// Ceilings the owner is shown, and the runtime enforces, for every run.
pub const MAX_TOOL_CALLS: usize = 8;
pub const MAX_FETCH_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_RUN_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_RUN_SECONDS: i64 = 120;
pub const MAX_REQUEST_SECONDS: u64 = 20;
/// How many outbound web requests this Spark may make in any rolling hour, across every run and surface.
pub const MAX_CALLS_PER_HOUR: usize = 60;
/// How much of one page the model is shown.
pub const MAX_PAGE_CHARACTERS: usize = 40_000;
/// Redirect hops followed before a fetch gives up.
pub const MAX_REDIRECTS: usize = 3;

/// What the transport is asked to do; every field is decided by the runtime, never by the model.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportRequest {
    pub url: String,
    pub accept: &'static str,
    pub secret_header: Option<(&'static str, String)>,
    pub max_bytes: usize,
    pub timeout_seconds: u64,
    /// The addresses the guard already checked; the connection must use these and not resolve again.
    pub addresses: Vec<std::net::IpAddr>,
}

/// What came back, already bounded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportResponse {
    pub status: u16,
    pub location: Option<String>,
    pub content_type: String,
    pub body: String,
    pub bytes: usize,
}

/// The seam that lets every budget and refusal be proved without a network.
#[async_trait::async_trait]
pub trait WebTransport: Send + Sync {
    async fn get(&self, request: &TransportRequest) -> Result<TransportResponse, String>;
}

/// One line of the run's tool list, shown to the owner exactly as recorded.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ToolCallRecord {
    pub index: u32,
    pub tool: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub outcome: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_bytes: Option<u64>,
    pub duration_ms: i64,
}

impl ToolCallRecord {
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or_else(|_| json!({}))
    }
}

/// A page the answer drew on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub url: String,
    pub title: Option<String>,
}

/// Everything one run is allowed to do on the internet, and the record of what it did.
pub struct Session {
    settings: WebAccessSettings,
    /// Which part of the product this run belongs to; checked again on every call.
    surface: Surface,
    secret: Option<String>,
    guard: Guard,
    own: OwnNames,
    resolver: Arc<dyn HostResolver + Send + Sync>,
    transport: Arc<dyn WebTransport>,
    clock: Arc<dyn UtcClock>,
    started_at: i64,
    started_monotonic: tokio::time::Instant,
    calls: Vec<ToolCallRecord>,
    bytes_used: usize,
    robots: HashMap<String, Robots>,
    sources: Vec<Source>,
    /// Tool calls the model asked this run for, which is not the same as requests that went out.
    spent: usize,
    hourly_allowance: usize,
    /// The Spark-wide rolling-hour ceiling, and where the places taken in it are counted.
    hourly_ceiling: usize,
    ledger: Option<Arc<dyn CallLedger>>,
}

impl Session {
    pub fn new(
        settings: WebAccessSettings,
        surface: Surface,
        secret: Option<String>,
        own: OwnNames,
        resolver: Arc<dyn HostResolver + Send + Sync>,
        transport: Arc<dyn WebTransport>,
        clock: Arc<dyn UtcClock>,
    ) -> Self {
        let started_at = clock.now().unix_timestamp();
        Self {
            settings,
            surface,
            secret,
            guard: Guard::new(&own.hostname),
            own,
            resolver,
            transport,
            clock,
            started_at,
            started_monotonic: tokio::time::Instant::now(),
            calls: Vec::new(),
            bytes_used: 0,
            robots: HashMap::new(),
            sources: Vec::new(),
            spent: 0,
            hourly_allowance: MAX_TOOL_CALLS,
            hourly_ceiling: MAX_CALLS_PER_HOUR,
            ledger: None,
        }
    }

    /// Narrow this run to what is left of the Spark's rolling-hour ceiling, and reserve against it.
    pub fn with_hourly_allowance(mut self, remaining: usize) -> Self {
        self.hourly_allowance = remaining.min(MAX_TOOL_CALLS);
        if self.ledger.is_none() {
            self.hourly_ceiling = remaining;
            self.ledger = Some(ProcessLedger::shared());
        }
        self
    }

    /// Reserve and record against the Spark's durable ledger rather than this process's memory.
    pub fn with_call_ledger(mut self, ledger: Arc<dyn CallLedger>, ceiling: usize) -> Self {
        self.hourly_ceiling = ceiling;
        self.ledger = Some(ledger);
        self
    }

    /// Take one place in the Spark's rolling hour, before anything at all goes out.
    fn reserve(&self) -> bool {
        let now = self.clock.now().unix_timestamp();
        match &self.ledger {
            Some(ledger) => ledger.reserve(self.hourly_ceiling, now),
            None => true,
        }
    }

    pub fn records(&self) -> &[ToolCallRecord] {
        &self.calls
    }

    pub fn sources(&self) -> &[Source] {
        &self.sources
    }

    /// Why the run may not make another call, if it may not.
    pub fn exhausted(&self) -> Option<&'static str> {
        if let Err(code) = policy::permits(&self.settings, self.surface) {
            return Some(code);
        }
        if self.spent >= MAX_TOOL_CALLS {
            return Some("WEB_TOOL_CALL_LIMIT");
        }
        if self.spent >= self.hourly_allowance {
            return Some("WEB_HOURLY_LIMIT");
        }
        if self.bytes_used >= MAX_RUN_BYTES {
            return Some("WEB_RUN_BYTE_LIMIT");
        }
        if self.elapsed() >= MAX_RUN_SECONDS {
            return Some("WEB_RUN_TIME_LIMIT");
        }
        None
    }

    pub fn remaining(&self) -> std::time::Duration {
        let wall = std::time::Duration::from_secs(
            MAX_RUN_SECONDS.saturating_sub(self.elapsed()).max(0) as u64,
        );
        wall.min(
            std::time::Duration::from_secs(MAX_RUN_SECONDS as u64)
                .saturating_sub(self.started_monotonic.elapsed()),
        )
    }

    fn elapsed(&self) -> i64 {
        self.clock
            .now()
            .unix_timestamp()
            .saturating_sub(self.started_at)
            .max(
                self.started_monotonic
                    .elapsed()
                    .as_secs()
                    .min(i64::MAX as u64) as i64,
            )
    }

    fn millis(&self) -> i64 {
        (self.clock.now().unix_timestamp_nanos() / 1_000_000) as i64
    }

    /// Ask the configured search service and return the results as the model's tool turn.
    pub async fn search(&mut self, query: &str) -> String {
        if let Some(code) = self.exhausted() {
            return refusal_text(code, stopped_explanation(code));
        }
        self.spent += 1;
        let started = self.millis();
        if let Some(finding) = outbound::scan_query(query, &self.own) {
            self.record(
                "web_search",
                Some(query),
                None,
                "refused",
                Some(outbound::BLOCKED_CODE),
                None,
                started,
            );
            return refusal_text(outbound::BLOCKED_CODE, finding.explanation());
        }
        let request = match backend::search_request(&self.settings, query, self.secret.as_deref()) {
            Ok(request) => request,
            Err(code) => {
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "refused",
                    Some(code),
                    None,
                    started,
                );
                return refusal_text(code, search_explanation(code));
            }
        };
        let addresses = match self.search_addresses(&request.url).await {
            Ok(addresses) => addresses,
            Err((code, explanation)) => {
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "refused",
                    Some(code),
                    None,
                    started,
                );
                return refusal_text(code, explanation);
            }
        };
        if !self.reserve() {
            self.record(
                "web_search",
                Some(query),
                None,
                "refused",
                Some("WEB_HOURLY_LIMIT"),
                None,
                started,
            );
            return refusal_text("WEB_HOURLY_LIMIT", stopped_explanation("WEB_HOURLY_LIMIT"));
        }
        let transport = TransportRequest {
            url: request.url.clone(),
            accept: request.accept,
            secret_header: request.secret_header,
            max_bytes: MAX_FETCH_BYTES,
            timeout_seconds: MAX_REQUEST_SECONDS,
            addresses,
        };
        match self.transport.get(&transport).await {
            Ok(response) if (200..300).contains(&response.status) => {
                self.bytes_used = self.bytes_used.saturating_add(response.bytes);
                let results = backend::parse_results(self.settings.backend, &response.body);
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "succeeded",
                    None,
                    Some(response.bytes as u64),
                    started,
                );
                render_results(query, &results)
            }
            Ok(response) => {
                self.bytes_used = self.bytes_used.saturating_add(response.bytes);
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "failed",
                    Some("WEB_SEARCH_UNAVAILABLE"),
                    None,
                    started,
                );
                refusal_text(
                    "WEB_SEARCH_UNAVAILABLE",
                    "The search service refused this request.",
                )
            }
            Err(_) => {
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "failed",
                    Some("WEB_SEARCH_UNAVAILABLE"),
                    None,
                    started,
                );
                refusal_text(
                    "WEB_SEARCH_UNAVAILABLE",
                    "The search service could not be reached.",
                )
            }
        }
    }

    /// A search leaves the house exactly as a fetch does: checked, then pinned to what was checked.
    async fn search_addresses(
        &self,
        url: &str,
    ) -> Result<Vec<std::net::IpAddr>, (&'static str, &'static str)> {
        if backend::is_packaged_searxng(url) {
            return Ok(backend::packaged_addresses(url));
        }
        match self.checked_destination(url).await {
            Ok(destination) => Ok(destination.addresses),
            Err(refusal) => Err((refusal.code(), refusal.explanation())),
        }
    }

    /// The synchronous resolver never blocks the async executor or the run's deadline.
    async fn checked_destination(
        &self,
        url: &str,
    ) -> Result<super::guard::Destination, super::guard::Refusal> {
        let guard = self.guard.clone();
        let resolver = self.resolver.clone();
        let url = url.to_owned();
        tokio::time::timeout(
            self.remaining()
                .min(std::time::Duration::from_secs(MAX_REQUEST_SECONDS)),
            tokio::task::spawn_blocking(move || guard.check(&url, resolver.as_ref())),
        )
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or(Err(super::guard::Refusal::Unresolvable))
    }

    /// Record that the owner's personal context was taken out of the transcript before the loop ran.
    pub fn record_context_stripped(&mut self) {
        let started = self.millis();
        self.record(
            "personal_context",
            None,
            None,
            "stripped",
            None,
            None,
            started,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn record(
        &mut self,
        tool: &str,
        query: Option<&str>,
        url: Option<&str>,
        outcome: &str,
        error_code: Option<&str>,
        result_bytes: Option<u64>,
        started_ms: i64,
    ) {
        let record = ToolCallRecord {
            index: self.calls.len() as u32,
            tool: tool.to_owned(),
            query: query
                .filter(|value| outbound::scan_query(value, &self.own).is_none())
                .map(|value| truncate(value, 400)),
            url: url
                .filter(|value| outbound::scan_url(value, &self.own).is_none())
                .map(|value| truncate(value, 2_048)),
            outcome: outcome.to_owned(),
            error_code: error_code.map(str::to_owned),
            result_bytes,
            duration_ms: self.millis().saturating_sub(started_ms).max(0),
        };
        // Written down as it happens, so a crash mid-run cannot lose a call that already went out.
        if let Some(ledger) = &self.ledger {
            ledger.append(&record);
        }
        self.calls.push(record);
    }
}

mod fetching;
mod wording;

#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;

//! Rate-limit by authenticated device or transport peer and operation class; untrusted device headers cannot select another budget.

use std::collections::{HashMap, VecDeque};
use std::net::{IpAddr, Ipv6Addr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, Request, State};
use axum::http::StatusCode;
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use parking_lot::Mutex;
use serde_json::json;

use crate::clock::UtcClock;

/// How long a bucket may sit untouched before it is swept; every class refills fully well inside this.
const BUCKET_TTL: Duration = Duration::from_secs(600);

/// Local runtime clients share the loopback bucket, so it has additional capacity.
const LOOPBACK_BUDGET_FACTOR: f64 = 10.0;

/// A source of elapsed time that no clock step can move, so a forward jump cannot refill every bucket at once.
pub trait Monotonic: Send + Sync + 'static {
    fn now(&self) -> Instant;
}

struct SystemMonotonic;

impl Monotonic for SystemMonotonic {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// Drive elapsed time by hand in tests, independently of the wall clock.
pub struct ManualMonotonic {
    base: Instant,
    offset: Mutex<Duration>,
}

impl Default for ManualMonotonic {
    fn default() -> Self {
        Self {
            base: Instant::now(),
            offset: Mutex::new(Duration::ZERO),
        }
    }
}

impl ManualMonotonic {
    pub fn advance(&self, by: Duration) {
        *self.offset.lock() += by;
    }
}

impl Monotonic for ManualMonotonic {
    fn now(&self) -> Instant {
        self.base + *self.offset.lock()
    }
}

/// Assign separate abuse budgets to device/operation classes (§16.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RateClass {
    /// Pairing challenge/claim and invitation issue.
    Pairing,
    /// Rejected authentication: counted against the source, not a device.
    AuthFailure,
    /// Terminal creation and attach.
    Terminal,
    /// Agent starts and change decisions.
    Agent,
    /// Build submission, claim, and result reporting.
    Build,
    /// Model install/load/unload and other durable model work.
    Model,
    /// On-demand remote health reconciliation: it drives a privileged helper that forks a probe as root.
    RemoteRefresh,
    /// Everything else on the authenticated surface.
    General,
}

impl RateClass {
    pub fn name(self) -> &'static str {
        match self {
            RateClass::Pairing => "pairing",
            RateClass::AuthFailure => "auth_failure",
            RateClass::Terminal => "terminal",
            RateClass::Agent => "agent",
            RateClass::Build => "build",
            RateClass::Model => "model",
            RateClass::RemoteRefresh => "remote_refresh",
            RateClass::General => "general",
        }
    }

    /// `(burst, refill per second)`.
    fn budget(self) -> (f64, f64) {
        match self {
            RateClass::Pairing => (10.0, 10.0 / 60.0),
            RateClass::AuthFailure => (20.0, 20.0 / 60.0),
            RateClass::Terminal => (10.0, 10.0 / 60.0),
            RateClass::Agent => (20.0, 20.0 / 60.0),
            RateClass::Build => (60.0, 1.0),
            RateClass::Model => (30.0, 0.5),
            RateClass::RemoteRefresh => (6.0, 6.0 / 60.0),
            RateClass::General => (240.0, 8.0),
        }
    }

    /// Classify a request by method and path.
    pub fn classify(method: &axum::http::Method, path: &str) -> RateClass {
        if method == axum::http::Method::POST && path == "/api/v1/remote/refresh" {
            return RateClass::RemoteRefresh;
        }
        if path.starts_with("/api/v1/pairing") {
            return RateClass::Pairing;
        }
        if method == axum::http::Method::POST && path == "/api/v1/remote/refresh" {
            return RateClass::RemoteRefresh;
        }
        if path.contains("/terminals") {
            return RateClass::Terminal;
        }
        if path.contains("/agents") || path.contains("/changes/") {
            return RateClass::Agent;
        }
        if path.starts_with("/api/v1/builds") || path.starts_with("/api/v1/build_workers") {
            return RateClass::Build;
        }
        if path.starts_with("/api/v1/models") || path.starts_with("/api/v1/inference") {
            if method == axum::http::Method::GET {
                return RateClass::General;
            }
            return RateClass::Model;
        }
        RateClass::General
    }
}

/// Principal whose requests share this budget.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Subject {
    Device(uuid::Uuid),
    Source(IpAddr),
    /// Local runtime clients share this bucket, separate from every LAN and Tailscale peer.
    Loopback,
    /// No connect info and no device: one shared bucket, deliberately small.
    Unattributed,
}

impl Subject {
    /// Local runtime clients use a shared budget with additional capacity.
    fn budget_factor(&self) -> f64 {
        match self {
            Subject::Loopback => LOOPBACK_BUDGET_FACTOR,
            _ => 1.0,
        }
    }
}

/// Hard ceiling on tracked buckets: past it the oldest admissions are evicted in O(1), so fresh source addresses cannot grow memory or scan time.
pub const MAX_BUCKETS: usize = 8_192;

#[derive(Debug, Clone, Copy)]
struct Bucket {
    tokens: f64,
    updated: Instant,
    // Match the newest use slot so a bucket touched since is never evicted by a stale slot.
    generation: u64,
}

/// Keep the use queue from growing with traffic; compaction is amortised O(1) per admission.
const MAX_ORDER_SLOTS: usize = MAX_BUCKETS * 4;

#[derive(Default)]
struct Buckets {
    map: HashMap<(Subject, RateClass), Bucket>,
    order: VecDeque<((Subject, RateClass), u64)>,
    next_generation: u64,
}

impl Buckets {
    fn bucket(&mut self, key: (Subject, RateClass), now: Instant, burst: f64) -> &mut Bucket {
        if !self.map.contains_key(&key) {
            self.sweep_expired(now);
            self.evict_for_insert();
            self.map.insert(
                key.clone(),
                Bucket {
                    tokens: burst,
                    updated: now,
                    generation: 0,
                },
            );
        }
        // Record this use at the back so eviction takes the least recently used bucket, never the oldest.
        let generation = self.next_generation;
        self.next_generation += 1;
        self.order.push_back((key.clone(), generation));
        self.compact();
        let bucket = self.map.get_mut(&key).expect("bucket inserted above");
        bucket.generation = generation;
        bucket
    }

    // Drop buckets nobody has touched for a full TTL; by then every class has refilled, so nothing is lost.
    fn sweep_expired(&mut self, now: Instant) {
        while let Some((key, generation)) = self.order.front() {
            let Some(bucket) = self.map.get(key) else {
                self.order.pop_front();
                continue;
            };
            if bucket.generation != *generation {
                self.order.pop_front();
                continue;
            }
            if now.saturating_duration_since(bucket.updated) < BUCKET_TTL {
                return;
            }
            let key = key.clone();
            self.order.pop_front();
            self.map.remove(&key);
        }
    }

    // Pop use slots until there is room; a slot whose bucket was touched since is skipped, so the victim is the least recently used.
    fn evict_for_insert(&mut self) {
        while self.map.len() >= MAX_BUCKETS {
            let Some((key, generation)) = self.order.pop_front() else {
                break;
            };
            if self
                .map
                .get(&key)
                .is_some_and(|bucket| bucket.generation == generation)
            {
                self.map.remove(&key);
            }
        }
    }

    // Drop superseded use slots in one pass rather than letting the queue grow with traffic.
    fn compact(&mut self) {
        if self.order.len() <= MAX_ORDER_SLOTS {
            return;
        }
        let map = &self.map;
        self.order
            .retain(|(key, generation)| map.get(key).is_some_and(|b| b.generation == *generation));
    }
}

/// Shared limiter. Cheap to clone; state lives behind one mutex.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<Mutex<Buckets>>,
    monotonic: Arc<dyn Monotonic>,
    enabled: bool,
}

impl RateLimiter {
    /// The wall clock is no longer read: refill deltas come from a monotonic source, so a forward step cannot refill every bucket at once.
    pub fn new(_clock: Arc<dyn UtcClock>) -> Self {
        Self::with_monotonic(Arc::new(SystemMonotonic))
    }

    pub fn with_monotonic(monotonic: Arc<dyn Monotonic>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(Buckets::default())),
            monotonic,
            enabled: true,
        }
    }

    /// Disable throttling explicitly for tests that intentionally issue many requests.
    pub fn disabled(clock: Arc<dyn UtcClock>) -> Self {
        Self {
            enabled: false,
            ..Self::new(clock)
        }
    }

    /// Take one token. `Err(retry_after_seconds)` when the bucket is empty.
    pub fn admit(&self, subject: Subject, class: RateClass) -> Result<(), u64> {
        if !self.enabled {
            return Ok(());
        }
        let factor = subject.budget_factor();
        let (base_burst, base_refill) = class.budget();
        let (burst, refill) = (base_burst * factor, base_refill * factor);
        let now = self.monotonic.now();
        let mut buckets = self.inner.lock();
        // Eviction takes the least recently used bucket, so an active subject is never evicted into a fresh burst.
        let bucket = buckets.bucket((subject, class), now, burst);
        let elapsed = now.saturating_duration_since(bucket.updated).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * refill).min(burst);
        bucket.updated = now;
        if bucket.tokens < 1.0 {
            let deficit = 1.0 - bucket.tokens;
            return Err((deficit / refill).ceil().max(1.0) as u64);
        }
        bucket.tokens -= 1.0;
        Ok(())
    }
}

impl RateLimiter {
    /// Key an unauthenticated request by its socket peer; forwarded headers never confer identity.
    pub fn unauthenticated(&self, state: &crate::state::AppState, request: &Request) -> Subject {
        let _ = state;
        unauthenticated_subject(request)
    }
}

pub(crate) fn rate_limited(retry_after: u64) -> Response {
    (
        StatusCode::TOO_MANY_REQUESTS,
        [("retry-after", retry_after.to_string())],
        axum::Json(json!({
            "error": {
                "code": "RATE_LIMITED",
                "message": "too many requests for this operation class",
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
        .into_response()
}

/// Number of buckets currently tracked, for tests and diagnostics.
pub fn tracked_buckets(limiter: &RateLimiter) -> usize {
    limiter.inner.lock().map.len()
}

/// Charge IPv6 peers per /64 so one host's address space is one budget; IPv4-mapped peers keep their IPv4 budget.
pub fn source_prefix(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(v4) => IpAddr::V4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(Ipv6Addr::from(u128::from(v6) & !((1u128 << 64) - 1))),
        },
    }
}

/// Attribute requests to their transport peer; forwarded headers are never authoritative.
pub fn unauthenticated_subject(request: &Request) -> Subject {
    let Some(peer) = request
        .extensions()
        .get::<ConnectInfo<std::net::SocketAddr>>()
        .map(|info| info.0.ip())
    else {
        return Subject::Unattributed;
    };
    if peer.is_loopback() {
        Subject::Loopback
    } else {
        Subject::Source(source_prefix(peer))
    }
}

/// Limit failed authentication by transport peer inside authentication, before the authenticated-device limiter can run.
pub(crate) fn reject_authentication_abuse(
    state: &crate::state::AppState,
    request: &Request,
) -> Option<Response> {
    let subject = state.rate_limiter.unauthenticated(state, request);
    match state.rate_limiter.admit(subject, RateClass::AuthFailure) {
        Ok(()) => None,
        Err(retry_after) => {
            tracing::warn!(
                class = RateClass::AuthFailure.name(),
                retry_after,
                "authentication source rate limited"
            );
            Some(rate_limited(retry_after))
        }
    }
}

/// After authentication, charge the device grant rather than a shared peer address, before authorization.
pub async fn limit(
    State(state): State<crate::state::AppState>,
    request: Request,
    next: Next,
) -> Response {
    let class = RateClass::classify(request.method(), request.uri().path());
    let subject = request
        .extensions()
        .get::<crate::auth::Principal>()
        .map(|principal| Subject::Device(principal.device_id))
        .unwrap_or_else(|| state.rate_limiter.unauthenticated(&state, &request));

    if let Err(retry_after) = state.rate_limiter.admit(subject, class) {
        tracing::warn!(class = class.name(), retry_after, "request rate limited");
        return rate_limited(retry_after);
    }
    next.run(request).await
}

#[cfg(test)]
#[path = "ratelimit/tests.rs"]
mod tests;

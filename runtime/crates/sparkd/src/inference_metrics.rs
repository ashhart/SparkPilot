//! Read engine metrics only from trusted loopback ports without client-selected URLs or inference calls.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::Serialize;
use spark_privd::PrivilegedOperation;
use spark_privd::workloads::{ObservedContainer, ObservedWorkloads};
use spark_telemetry::VllmMetrics;

use crate::privd::PrivilegedClient;

const SCRAPE_TIMEOUT: Duration = Duration::from_millis(500);
const MAX_SCRAPE_BYTES: usize = 512 * 1024;
const MIN_SCRAPE_INTERVAL: Duration = Duration::from_secs(2);
const MAX_STALE_AGE: Duration = Duration::from_secs(15);
const TARGET_REFRESH_INTERVAL: Duration = Duration::from_secs(5);
const MAX_STALE_TARGET_AGE: Duration = Duration::from_secs(30);
const INVENTORY_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_ENGINES: usize = 8;
const MAX_CACHED_ENGINES: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EngineMetricsTarget {
    pub workload_id: String,
    pub engine: &'static str,
    pub ownership: &'static str,
    pub port: Option<u16>,
    pub model_hint: Option<String>,
}

impl EngineMetricsTarget {
    pub fn managed_vllm(port: u16, model: Option<String>) -> Self {
        Self::managed("vllm", port, model)
    }

    pub fn managed(engine: &'static str, port: u16, model: Option<String>) -> Self {
        Self {
            workload_id: "spark-managed".to_owned(),
            engine,
            ownership: "spark_managed",
            port: Some(port),
            model_hint: model,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EngineMetricsReport {
    pub workload_id: String,
    pub engine: &'static str,
    pub ownership: &'static str,
    pub availability: &'static str,
    pub observed_at: Option<String>,
    pub sample_age_seconds: Option<u64>,
    pub served_model: Option<String>,
    pub engine_uptime_seconds: Option<u64>,
    pub total_requests: Option<u64>,
    pub prompt_tokens: Option<u64>,
    pub generated_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub running_requests: Option<u64>,
    pub queue_depth: Option<u64>,
    pub prompt_tokens_per_second: Option<f64>,
    pub generation_tokens_per_second: Option<f64>,
    pub request_latency_ms: Option<f64>,
    pub time_to_first_token_ms: Option<f64>,
    pub time_per_output_token_ms: Option<f64>,
}

impl EngineMetricsReport {
    fn empty(target: &EngineMetricsTarget, availability: &'static str) -> Self {
        Self {
            workload_id: target.workload_id.clone(),
            engine: target.engine,
            ownership: target.ownership,
            availability,
            observed_at: None,
            sample_age_seconds: None,
            served_model: target.model_hint.clone(),
            engine_uptime_seconds: None,
            total_requests: None,
            prompt_tokens: None,
            generated_tokens: None,
            total_tokens: None,
            running_requests: None,
            queue_depth: None,
            prompt_tokens_per_second: None,
            generation_tokens_per_second: None,
            request_latency_ms: None,
            time_to_first_token_ms: None,
            time_per_output_token_ms: None,
        }
    }
}

#[derive(Clone)]
struct SuccessfulSample {
    collected_at: Instant,
    metrics: VllmMetrics,
    report: EngineMetricsReport,
}

#[derive(Default)]
struct CachedEngine {
    last_attempt: Option<Instant>,
    successful: Option<SuccessfulSample>,
}

#[derive(Default)]
struct TargetCache {
    last_attempt: Option<Instant>,
    last_success: Option<Instant>,
    targets: Vec<EngineMetricsTarget>,
}

pub struct InferenceMetricsCollector {
    client: Option<reqwest::Client>,
    samples: Mutex<HashMap<EngineMetricsTarget, CachedEngine>>,
    targets: Mutex<TargetCache>,
}

impl Default for InferenceMetricsCollector {
    fn default() -> Self {
        let client = reqwest::Client::builder()
            .connect_timeout(SCRAPE_TIMEOUT)
            .timeout(SCRAPE_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .ok();
        Self {
            client,
            samples: Mutex::new(HashMap::new()),
            targets: Mutex::new(TargetCache::default()),
        }
    }
}

impl InferenceMetricsCollector {
    pub async fn external_targets(
        &self,
        privileged: Option<PrivilegedClient>,
    ) -> Vec<EngineMetricsTarget> {
        let now = Instant::now();
        {
            let mut cache = self.targets.lock();
            if cache
                .last_attempt
                .is_some_and(|attempt| now.duration_since(attempt) < TARGET_REFRESH_INTERVAL)
            {
                return cache.targets.clone();
            }
            cache.last_attempt = Some(now);
        }

        let observed = match privileged {
            Some(privileged) => tokio::task::spawn_blocking(move || {
                privileged.call_bounded(
                    PrivilegedOperation::InventoryWorkloads {
                        request_id: uuid::Uuid::new_v4(),
                    },
                    INVENTORY_TIMEOUT,
                )
            })
            .await
            .ok()
            .and_then(Result::ok)
            .filter(|response| response.accepted)
            .and_then(|response| {
                serde_json::from_value::<ObservedWorkloads>(response.details).ok()
            }),
            None => None,
        };

        let mut cache = self.targets.lock();
        if let Some(observed) = observed {
            cache.targets = targets_from_workloads(&observed);
            cache.last_success = Some(now);
        } else if cache
            .last_success
            .is_none_or(|success| now.duration_since(success) > MAX_STALE_TARGET_AGE)
        {
            cache.targets.clear();
        }
        cache.targets.clone()
    }

    pub async fn collect(
        &self,
        target: EngineMetricsTarget,
        observed_at: String,
        observed_unix_seconds: i64,
    ) -> EngineMetricsReport {
        if target.engine != "vllm" {
            return EngineMetricsReport::empty(&target, "unsupported");
        }
        let Some(port) = target.port else {
            return EngineMetricsReport::empty(&target, "unavailable");
        };
        let now = Instant::now();
        {
            let mut cache = self.samples.lock();
            if let Some(entry) = cache.get(&target)
                && entry
                    .last_attempt
                    .is_some_and(|attempt| now.duration_since(attempt) < MIN_SCRAPE_INTERVAL)
            {
                return cached_report(entry, &target, now, MAX_STALE_AGE);
            }
            if !cache.contains_key(&target) && cache.len() >= MAX_CACHED_ENGINES {
                let oldest = cache
                    .iter()
                    .min_by_key(|(_, entry)| entry.last_attempt)
                    .map(|(key, _)| key.clone());
                if let Some(oldest) = oldest {
                    cache.remove(&oldest);
                }
            }
            cache.entry(target.clone()).or_default().last_attempt = Some(now);
        }

        let scrape = match &self.client {
            Some(client) => scrape_vllm_metrics(client, port).await,
            None => None,
        };
        let Some(metrics) = scrape else {
            let cache = self.samples.lock();
            return cache.get(&target).map_or_else(
                || EngineMetricsReport::empty(&target, "unavailable"),
                |entry| cached_report(entry, &target, now, MAX_STALE_AGE),
            );
        };

        let previous = self
            .samples
            .lock()
            .get(&target)
            .and_then(|entry| entry.successful.clone());
        let elapsed = previous
            .as_ref()
            .map(|sample| now.duration_since(sample.collected_at));
        let total_tokens = match (metrics.prompt_tokens_total, metrics.generation_tokens_total) {
            (Some(prompt), Some(generated)) => Some(prompt.saturating_add(generated)),
            _ => None,
        };
        let report = EngineMetricsReport {
            workload_id: target.workload_id.clone(),
            engine: target.engine,
            ownership: target.ownership,
            availability: "live",
            observed_at: Some(observed_at),
            sample_age_seconds: Some(0),
            served_model: metrics
                .served_model
                .clone()
                .or_else(|| target.model_hint.clone()),
            engine_uptime_seconds: metrics.process_start_time_seconds.and_then(|started| {
                let now = observed_unix_seconds as f64;
                (started >= 0.0 && started <= now + 1.0).then_some((now - started).max(0.0) as u64)
            }),
            total_requests: metrics.requests_total,
            prompt_tokens: metrics.prompt_tokens_total,
            generated_tokens: metrics.generation_tokens_total,
            total_tokens,
            running_requests: metrics.num_requests_running,
            queue_depth: metrics.num_requests_waiting,
            prompt_tokens_per_second: rate(
                metrics.prompt_tokens_total,
                previous
                    .as_ref()
                    .and_then(|sample| sample.metrics.prompt_tokens_total),
                elapsed,
            ),
            generation_tokens_per_second: rate(
                metrics.generation_tokens_total,
                previous
                    .as_ref()
                    .and_then(|sample| sample.metrics.generation_tokens_total),
                elapsed,
            ),
            request_latency_ms: metrics.request_latency_ms,
            time_to_first_token_ms: metrics.time_to_first_token_ms,
            time_per_output_token_ms: metrics.time_per_output_token_ms,
        };
        self.samples.lock().entry(target).or_default().successful = Some(SuccessfulSample {
            collected_at: now,
            metrics,
            report: report.clone(),
        });
        report
    }
}

fn cached_report(
    entry: &CachedEngine,
    target: &EngineMetricsTarget,
    now: Instant,
    max_age: Duration,
) -> EngineMetricsReport {
    let Some(sample) = &entry.successful else {
        return EngineMetricsReport::empty(target, "unavailable");
    };
    let age = now.duration_since(sample.collected_at);
    if age > max_age {
        return EngineMetricsReport::empty(target, "unavailable");
    }
    let mut report = sample.report.clone();
    report.availability = "cached";
    report.sample_age_seconds = Some(age.as_secs());
    report
}

fn rate(current: Option<u64>, previous: Option<u64>, elapsed: Option<Duration>) -> Option<f64> {
    let (current, previous, elapsed) = (current?, previous?, elapsed?);
    let seconds = elapsed.as_secs_f64();
    if current < previous || seconds <= 0.0 {
        return None;
    }
    Some((current - previous) as f64 / seconds)
}

async fn scrape_vllm_metrics(client: &reqwest::Client, port: u16) -> Option<VllmMetrics> {
    let mut response = client
        .get(format!("http://127.0.0.1:{port}/metrics"))
        .send()
        .await
        .ok()?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > MAX_SCRAPE_BYTES as u64)
    {
        return None;
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if body.len().saturating_add(chunk.len()) > MAX_SCRAPE_BYTES {
            return None;
        }
        body.extend_from_slice(&chunk);
    }
    let metrics = spark_telemetry::parse_vllm_metrics(std::str::from_utf8(&body).ok()?);
    metrics.is_vllm_sample().then_some(metrics)
}

fn targets_from_workloads(observed: &ObservedWorkloads) -> Vec<EngineMetricsTarget> {
    observed
        .containers
        .iter()
        .filter(|container| container.state == "running")
        .filter_map(target_from_container)
        .take(MAX_ENGINES)
        .collect()
}

fn target_from_container(container: &ObservedContainer) -> Option<EngineMetricsTarget> {
    let engine = recognised_engine(container.image.as_deref()?)?;
    let tcp_ports: HashSet<u16> = container
        .ports
        .iter()
        .filter(|port| port.protocol == "tcp" && port.host_port > 0)
        .map(|port| port.host_port)
        .collect();
    let preferred = container
        .ports
        .iter()
        .find(|port| port.protocol == "tcp" && port.host_port > 0 && port.container_port == 8000)
        .map(|port| port.host_port);
    let port = preferred.or_else(|| {
        (tcp_ports.len() == 1)
            .then(|| tcp_ports.iter().next().copied())
            .flatten()
    });
    Some(EngineMetricsTarget {
        workload_id: container.id.clone(),
        engine,
        ownership: "external_observed",
        port,
        model_hint: None,
    })
}

/// Recognize engines by the image repository's final path segment rather than unrelated namespace text.
fn recognised_engine(image: &str) -> Option<&'static str> {
    let repository = image.split('@').next().unwrap_or(image);
    let repository = match repository.rfind(':') {
        Some(index) if index > repository.rfind('/').unwrap_or(0) => &repository[..index],
        _ => repository,
    };
    let last = repository.rsplit('/').next().unwrap_or(repository);
    match last.to_ascii_lowercase().as_str() {
        "vllm" | "vllm-openai" => Some("vllm"),
        "sglang" => Some("sglang"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use axum::Router;
    use axum::routing::get;

    use super::*;
    use spark_privd::workloads::ObservedPort;

    #[test]
    fn a_counter_reset_does_not_create_a_negative_or_wrapped_rate() {
        assert_eq!(rate(Some(10), Some(20), Some(Duration::from_secs(2))), None);
        assert_eq!(
            rate(Some(30), Some(20), Some(Duration::from_secs(2))),
            Some(5.0)
        );
    }

    #[test]
    fn only_recognised_running_engines_supply_loopback_targets() {
        let observed = ObservedWorkloads {
            containers: vec![
                ObservedContainer {
                    id: "aa".into(),
                    name: Some("existing-vllm".into()),
                    state: "running".into(),
                    image: Some("vllm/vllm-openai:v0.10".into()),
                    ports: vec![ObservedPort {
                        host_ip: "0.0.0.0".into(),
                        host_port: 18_000,
                        container_port: 8000,
                        protocol: "tcp".into(),
                    }],
                },
                ObservedContainer {
                    id: "bb".into(),
                    name: Some("unrelated".into()),
                    state: "running".into(),
                    image: Some("example/metrics:latest".into()),
                    ports: vec![ObservedPort {
                        host_ip: "0.0.0.0".into(),
                        host_port: 19_000,
                        container_port: 8000,
                        protocol: "tcp".into(),
                    }],
                },
            ],
            truncated: false,
            unreadable_lines: 0,
        };
        let targets = targets_from_workloads(&observed);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].port, Some(18_000));
        assert_eq!(targets[0].engine, "vllm");
    }

    #[tokio::test]
    async fn a_fresh_sample_is_cached_instead_of_hammering_the_engine() {
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_for_route = calls.clone();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().route(
            "/metrics",
            get(move || {
                let calls = calls_for_route.clone();
                async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    "vllm:num_requests_running 2\nvllm:prompt_tokens_total 100\n"
                }
            }),
        );
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let collector = InferenceMetricsCollector::default();
        let target = EngineMetricsTarget::managed_vllm(port, Some("model".into()));

        let first = collector
            .collect(target.clone(), "2026-08-31T12:00:00Z".into(), 1_788_177_600)
            .await;
        let second = collector
            .collect(target, "2026-08-31T12:00:01Z".into(), 1_788_177_601)
            .await;

        assert_eq!(first.availability, "live");
        assert_eq!(first.running_requests, Some(2));
        assert_eq!(second.availability, "cached");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        server.abort();
    }

    #[tokio::test]
    async fn oversized_metrics_are_unavailable() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().route(
            "/metrics",
            get(|| async { vec![b'x'; MAX_SCRAPE_BYTES + 1] }),
        );
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let collector = InferenceMetricsCollector::default();
        let report = collector
            .collect(
                EngineMetricsTarget::managed_vllm(port, None),
                "2026-08-31T12:00:00Z".into(),
                1_788_177_600,
            )
            .await;
        assert_eq!(report.availability, "unavailable");
        assert_eq!(report.prompt_tokens, None);
        server.abort();
    }

    #[tokio::test]
    async fn a_different_prometheus_service_on_the_port_is_not_called_vllm() {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().route(
            "/metrics",
            get(|| async { "process_start_time_seconds 1700000000\nhttp_requests_total 12\n" }),
        );
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let collector = InferenceMetricsCollector::default();
        let report = collector
            .collect(
                EngineMetricsTarget::managed_vllm(port, None),
                "2026-08-31T12:00:00Z".into(),
                1_788_177_600,
            )
            .await;

        assert_eq!(report.availability, "unavailable");
        assert_eq!(report.engine_uptime_seconds, None);
        server.abort();
    }

    #[tokio::test]
    async fn an_unavailable_endpoint_is_not_retried_on_every_dashboard_refresh() {
        let calls = Arc::new(AtomicUsize::new(0));
        let calls_for_route = calls.clone();
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let app = Router::new().route(
            "/metrics",
            get(move || {
                let calls = calls_for_route.clone();
                async move {
                    calls.fetch_add(1, Ordering::SeqCst);
                    axum::http::StatusCode::SERVICE_UNAVAILABLE
                }
            }),
        );
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let collector = InferenceMetricsCollector::default();
        let target = EngineMetricsTarget::managed_vllm(port, None);

        for second in 0..2 {
            let report = collector
                .collect(
                    target.clone(),
                    format!("2026-08-31T12:00:0{second}Z"),
                    1_788_177_600 + second,
                )
                .await;
            assert_eq!(report.availability, "unavailable");
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        server.abort();
    }
}

//! Parse selected vLLM Prometheus metrics without an engine; sparkd owns the loopback scraper.

use std::collections::{HashMap, HashSet};

/// Normalised inference metrics from one scrape.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct VllmMetrics {
    observed_vllm_family: bool,
    pub num_requests_running: Option<u64>,
    pub num_requests_waiting: Option<u64>,
    pub gpu_cache_usage: Option<f64>,
    pub prompt_tokens_total: Option<u64>,
    pub generation_tokens_total: Option<u64>,
    pub requests_total: Option<u64>,
    /// Unix timestamp exported by the engine process collector.
    pub process_start_time_seconds: Option<f64>,
    /// The single model name exported by the endpoint, when unambiguous.
    pub served_model: Option<String>,
    /// Mean time-to-first-token across observed requests, milliseconds.
    pub time_to_first_token_ms: Option<f64>,
    /// Mean inter-token (per-output-token) latency, milliseconds.
    pub time_per_output_token_ms: Option<f64>,
    /// Mean end-to-end request latency, milliseconds.
    pub request_latency_ms: Option<f64>,
}

impl VllmMetrics {
    /// True only when the scrape contained a metric family this parser knows.
    pub fn is_vllm_sample(&self) -> bool {
        self.observed_vllm_family
    }
}

/// Accept HELP/TYPE comments, labels and histogram sum/count components; ignore unknown metric families.
pub fn parse_vllm_metrics(text: &str) -> VllmMetrics {
    let mut samples: HashMap<String, f64> = HashMap::new();
    let mut histograms: HashMap<String, (f64, f64)> = HashMap::new();
    let mut model_names = HashSet::new();

    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (name, labels, value) = match parse_sample(line) {
            Some(pair) => pair,
            None => continue,
        };
        let supported_family = is_supported_family(name);
        if supported_family
            && let Some(model_name) = label_value(labels, "model_name")
            && model_name.len() <= 240
            && !model_name.chars().any(char::is_control)
        {
            model_names.insert(model_name);
        }
        if let Some(base) = name.strip_suffix("_sum") {
            let entry = histograms.entry(base.to_owned()).or_insert((0.0, 0.0));
            entry.0 += value;
        } else if let Some(base) = name.strip_suffix("_count") {
            let entry = histograms.entry(base.to_owned()).or_insert((0.0, 0.0));
            entry.1 += value;
        } else {
            *samples.entry(name.to_owned()).or_default() += value;
        }
    }

    let mean_ms = |family: &str| -> Option<f64> {
        histograms
            .get(family)
            .and_then(|&(sum, count)| (count > 0.0).then_some(sum / count * 1000.0))
    };

    let sample = |names: &[&str]| names.iter().find_map(|name| samples.get(*name).copied());
    let request_success = sample(&["vllm:request_success_total", "vllm_request_success_total"])
        .and_then(exact_non_negative_u64);
    let request_failure = sample(&["vllm:request_failure_total", "vllm_request_failure_total"])
        .and_then(exact_non_negative_u64);
    let requests_total = match (request_success, request_failure) {
        (Some(success), Some(failure)) => Some(success.saturating_add(failure)),
        (Some(success), None) => Some(success),
        (None, Some(failure)) => Some(failure),
        (None, None) => None,
    };
    let histogram_mean_ms = |families: &[&str]| families.iter().find_map(|family| mean_ms(family));

    VllmMetrics {
        observed_vllm_family: samples
            .keys()
            .chain(histograms.keys())
            .any(|name| is_supported_family(name)),
        num_requests_running: sample(&["vllm:num_requests_running", "vllm_num_requests_running"])
            .and_then(exact_non_negative_u64),
        num_requests_waiting: sample(&["vllm:num_requests_waiting", "vllm_num_requests_waiting"])
            .and_then(exact_non_negative_u64),
        gpu_cache_usage: sample(&["vllm:gpu_cache_usage_perc", "vllm_gpu_cache_usage_perc"])
            .filter(|value| value.is_finite() && *value >= 0.0)
            .map(|value| value.min(1.0)),
        prompt_tokens_total: sample(&["vllm:prompt_tokens_total", "vllm_prompt_tokens_total"])
            .and_then(exact_non_negative_u64),
        generation_tokens_total: sample(&[
            "vllm:generation_tokens_total",
            "vllm_generation_tokens_total",
        ])
        .and_then(exact_non_negative_u64),
        requests_total,
        process_start_time_seconds: sample(&["process_start_time_seconds"])
            .filter(|value| value.is_finite() && *value >= 0.0),
        served_model: (model_names.len() == 1)
            .then(|| model_names.into_iter().next())
            .flatten(),
        time_to_first_token_ms: histogram_mean_ms(&[
            "vllm:time_to_first_token_seconds",
            "vllm_time_to_first_token_seconds",
        ]),
        time_per_output_token_ms: histogram_mean_ms(&[
            "vllm:time_per_output_token_seconds",
            "vllm:inter_token_latency_seconds",
            "vllm_time_per_output_token_seconds",
            "vllm_inter_token_latency_seconds",
        ]),
        request_latency_ms: histogram_mean_ms(&[
            "vllm:e2e_request_latency_seconds",
            "vllm_e2e_request_latency_seconds",
        ]),
    }
}

fn is_supported_family(name: &str) -> bool {
    let name = name
        .strip_suffix("_bucket")
        .or_else(|| name.strip_suffix("_sum"))
        .or_else(|| name.strip_suffix("_count"))
        .unwrap_or(name);
    matches!(
        name,
        "vllm:num_requests_running"
            | "vllm_num_requests_running"
            | "vllm:num_requests_waiting"
            | "vllm_num_requests_waiting"
            | "vllm:gpu_cache_usage_perc"
            | "vllm_gpu_cache_usage_perc"
            | "vllm:prompt_tokens_total"
            | "vllm_prompt_tokens_total"
            | "vllm:generation_tokens_total"
            | "vllm_generation_tokens_total"
            | "vllm:request_success_total"
            | "vllm_request_success_total"
            | "vllm:request_failure_total"
            | "vllm_request_failure_total"
            | "vllm:time_to_first_token_seconds"
            | "vllm_time_to_first_token_seconds"
            | "vllm:time_per_output_token_seconds"
            | "vllm:inter_token_latency_seconds"
            | "vllm_time_per_output_token_seconds"
            | "vllm_inter_token_latency_seconds"
            | "vllm:e2e_request_latency_seconds"
            | "vllm_e2e_request_latency_seconds"
    )
}

fn exact_non_negative_u64(value: f64) -> Option<u64> {
    (value.is_finite()
        && value >= 0.0
        && value.fract() == 0.0
        && value < 9_223_372_036_854_775_808.0)
        .then_some(value as u64)
}

/// Split `name{labels} value [timestamp]` into its name and value.
fn parse_sample(line: &str) -> Option<(&str, Option<&str>, f64)> {
    let (identifier, rest) = match line.find(char::is_whitespace) {
        Some(idx) => (&line[..idx], line[idx..].trim_start()),
        None => (line, ""),
    };
    let value_token = rest.split_whitespace().next()?;
    let value: f64 = value_token.parse().ok()?;
    if !value.is_finite() {
        return None;
    }
    let (name, labels) = match identifier.split_once('{') {
        Some((name, labels)) => (name.trim(), labels.strip_suffix('}')),
        None => (identifier.trim(), None),
    };
    if name.is_empty() {
        return None;
    }
    Some((name, labels, value))
}

/// Reject partial labels and unknown escapes rather than accepting an ambiguous model identity.
fn label_value(labels: Option<&str>, wanted: &str) -> Option<String> {
    let labels = labels?;
    for field in labels.split(',') {
        let (name, raw) = field.trim().split_once('=')?;
        if name.trim() != wanted {
            continue;
        }
        let raw = raw.trim();
        let quoted = raw.strip_prefix('"')?.strip_suffix('"')?;
        let mut value = String::with_capacity(quoted.len());
        let mut chars = quoted.chars();
        while let Some(character) = chars.next() {
            if character != '\\' {
                value.push(character);
                continue;
            }
            match chars.next()? {
                '\\' => value.push('\\'),
                '"' => value.push('"'),
                'n' => value.push('\n'),
                _ => return None,
            }
        }
        return Some(value);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOLDEN: &str = r#"
# HELP vllm:num_requests_running Number of requests currently running on GPU.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{model_name="test-model"} 3.0
# HELP vllm:num_requests_waiting Number of requests waiting to be processed.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting{model_name="test-model"} 1.0
# HELP vllm:gpu_cache_usage_perc GPU KV-cache usage.
# TYPE vllm:gpu_cache_usage_perc gauge
vllm:gpu_cache_usage_perc 0.4123
# HELP vllm:prompt_tokens_total Number of prefill tokens processed.
# TYPE vllm:prompt_tokens_total counter
vllm:prompt_tokens_total{model_name="test-model"} 18432.0
# HELP vllm:generation_tokens_total Number of generation tokens processed.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total{model_name="test-model"} 9216.0
# HELP vllm:request_success_total Number of successfully completed requests.
vllm:request_success_total{finished_reason="stop",model_name="test-model"} 31
vllm:request_success_total{finished_reason="length",model_name="test-model"} 9
process_start_time_seconds 1700000000
# HELP vllm:time_to_first_token_seconds Histogram of time to first token.
# TYPE vllm:time_to_first_token_seconds histogram
vllm:time_to_first_token_seconds_bucket{le="0.01"} 14.0
vllm:time_to_first_token_seconds_bucket{le="+Inf"} 40.0
vllm:time_to_first_token_seconds_sum 1.8
vllm:time_to_first_token_seconds_count 40.0
# HELP vllm:time_per_output_token_seconds Histogram of time per output token.
# TYPE vllm:time_per_output_token_seconds histogram
vllm:time_per_output_token_seconds_bucket{le="+Inf"} 4608.0
vllm:time_per_output_token_seconds_sum 73.728
vllm:time_per_output_token_seconds_count 4608.0
vllm:e2e_request_latency_seconds_sum 12
vllm:e2e_request_latency_seconds_count 40
# HELP vllm:some_future_metric Not yet consumed by the product schema.
# TYPE vllm:some_future_metric gauge
vllm:some_future_metric 7.0
"#;

    #[test]
    fn parses_the_golden_scrape() {
        let metrics = parse_vllm_metrics(GOLDEN);
        assert_eq!(metrics.num_requests_running, Some(3));
        assert_eq!(metrics.num_requests_waiting, Some(1));
        assert_eq!(metrics.gpu_cache_usage, Some(0.4123));
        assert_eq!(metrics.prompt_tokens_total, Some(18_432));
        assert_eq!(metrics.generation_tokens_total, Some(9216));
        assert_eq!(metrics.requests_total, Some(40));
        assert_eq!(metrics.process_start_time_seconds, Some(1_700_000_000.0));
        assert_eq!(metrics.served_model.as_deref(), Some("test-model"));
        // 1.8 s / 40 requests = 45 ms mean TTFT.
        assert_eq!(metrics.time_to_first_token_ms, Some(45.0));
        // 73.728 s / 4608 tokens = 16 ms mean inter-token latency.
        assert_eq!(metrics.time_per_output_token_ms, Some(16.0));
        assert_eq!(metrics.request_latency_ms, Some(300.0));
        assert!(metrics.is_vllm_sample());
    }

    #[test]
    fn empty_and_garbage_input_yield_defaults() {
        assert_eq!(parse_vllm_metrics(""), VllmMetrics::default());
        let metrics = parse_vllm_metrics("not a metric\n###\nvllm:x\n");
        assert_eq!(metrics, VllmMetrics::default());
    }

    #[test]
    fn unknown_families_are_ignored_not_errors() {
        let metrics = parse_vllm_metrics("vllm:some_future_metric 7.0\n");
        assert_eq!(metrics, VllmMetrics::default());
        assert!(!metrics.is_vllm_sample());
    }

    #[test]
    fn zero_count_histograms_report_no_mean() {
        let metrics = parse_vllm_metrics(
            "vllm:time_to_first_token_seconds_sum 0.0\nvllm:time_to_first_token_seconds_count 0.0\n",
        );
        assert_eq!(metrics.time_to_first_token_ms, None);
    }

    #[test]
    fn invalid_request_counts_stay_unavailable() {
        let metrics = parse_vllm_metrics(
            "vllm:num_requests_running NaN\nvllm:num_requests_waiting -1\nvllm:prompt_tokens_total 1.5\n",
        );
        assert_eq!(metrics.num_requests_running, None);
        assert_eq!(metrics.num_requests_waiting, None);
        assert_eq!(metrics.prompt_tokens_total, None);
    }

    #[test]
    fn labelled_series_are_aggregated_instead_of_overwriting_each_other() {
        let metrics = parse_vllm_metrics(
            "vllm:prompt_tokens_total{model_name=\"one\"} 10\n\
             vllm:prompt_tokens_total{model_name=\"two\"} 20\n\
             vllm:num_requests_running{model_name=\"one\"} 2\n\
             vllm:num_requests_running{model_name=\"two\"} 3\n\
             vllm:time_to_first_token_seconds_sum{model_name=\"one\"} 1\n\
             vllm:time_to_first_token_seconds_count{model_name=\"one\"} 2\n\
             vllm:time_to_first_token_seconds_sum{model_name=\"two\"} 2\n\
             vllm:time_to_first_token_seconds_count{model_name=\"two\"} 3\n",
        );
        assert_eq!(metrics.prompt_tokens_total, Some(30));
        assert_eq!(metrics.num_requests_running, Some(5));
        assert_eq!(metrics.time_to_first_token_ms, Some(600.0));
        assert_eq!(metrics.served_model, None);
    }
}

#[cfg(test)]
mod glm_cache_usage {
    #[test]
    fn cache_usage_rejects_invalid_values_and_bounds_valid_ratios() {
        for value in ["NaN", "+Inf", "-Inf", "-0.5"] {
            assert_eq!(
                super::parse_vllm_metrics(&format!("vllm:gpu_cache_usage_perc {value}"))
                    .gpu_cache_usage,
                None,
                "{value}"
            );
        }
        assert_eq!(
            super::parse_vllm_metrics("vllm:gpu_cache_usage_perc 1.5").gpu_cache_usage,
            Some(1.0)
        );
    }
}

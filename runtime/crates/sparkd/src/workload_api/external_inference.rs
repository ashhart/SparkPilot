use super::*;

/// Retain aliases only from credential-free, nonredirecting external model-list probes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ExternalConfiguration {
    pub(super) state: &'static str,
    pub(super) api_protocol: Option<&'static str>,
    pub(super) api_port: Option<u16>,
    pub(super) served_models: Vec<String>,
}

impl ExternalConfiguration {
    pub(super) fn not_applicable() -> Self {
        Self {
            state: "not_applicable",
            api_protocol: None,
            api_port: None,
            served_models: Vec::new(),
        }
    }

    fn unavailable() -> Self {
        Self {
            state: "unavailable",
            ..Self::not_applicable()
        }
    }

    pub(super) fn ambiguous() -> Self {
        Self {
            state: "ambiguous",
            ..Self::not_applicable()
        }
    }
}

/// Describe whether a managed launch could conflict with an unowned inference workload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExternalInferenceGuard {
    /// Allow explicit development composition without a privileged probe; production always supplies one.
    NotChecked,
    Clear,
    Active,
    /// The inventory could not be read in full, so nothing about other workloads is established.
    Unreadable,
    /// The inventory was read and holds a running workload this runtime cannot classify.
    Unrecognized,
}

/// Check bounded read-only inventory for recognized unowned inference before launching, without lifecycle commands.
pub(crate) async fn external_inference_guard(state: &AppState) -> ExternalInferenceGuard {
    let Some(privileged) = state.privileged.clone() else {
        return ExternalInferenceGuard::NotChecked;
    };
    let response = tokio::task::spawn_blocking(move || {
        privileged.call_bounded(
            PrivilegedOperation::InventoryWorkloads {
                request_id: uuid::Uuid::new_v4(),
            },
            OBSERVATION_TIMEOUT,
        )
    })
    .await;
    let Ok(Ok(response)) = response else {
        return ExternalInferenceGuard::Unreadable;
    };
    if !response.accepted {
        return ExternalInferenceGuard::Unreadable;
    }
    let Ok(observed) = serde_json::from_value::<ObservedWorkloads>(response.details) else {
        return ExternalInferenceGuard::Unreadable;
    };
    let database = state.database.clone();
    let managed = tokio::task::spawn_blocking(move || {
        database.map_or_else(ManagedIds::default, |database| managed_ids(&database))
    })
    .await
    .unwrap_or_default();

    guard_from_observation(&observed, &managed)
}

pub(super) fn guard_from_observation(
    observed: &ObservedWorkloads,
    managed: &ManagedIds,
) -> ExternalInferenceGuard {
    let active_external_engine = observed.containers.iter().any(|container| {
        let classification = classify(container, managed);
        classification.ownership != "spark_managed"
            && classification.kind == "inference_engine"
            && !matches!(container.state.as_str(), "exited" | "dead")
    });
    let unclassified_active_workload = observed.containers.iter().any(|container| {
        let classification = classify(container, managed);
        (classification.ownership == "unknown_external"
            || (classification.ownership != "spark_managed"
                && classification.kind == "cluster_runtime"))
            && !matches!(container.state.as_str(), "exited" | "dead")
    });
    if active_external_engine {
        ExternalInferenceGuard::Active
    } else if observed.truncated || observed.unreadable_lines > 0 {
        ExternalInferenceGuard::Unreadable
    } else if unclassified_active_workload {
        // Custom images may run inference without a recognized repository name or published Docker ports.
        ExternalInferenceGuard::Unrecognized
    } else {
        ExternalInferenceGuard::Clear
    }
}

/// Probe recognized model-list endpoints on loopback only, even when reported binds are wildcard or LAN addresses.
pub(super) async fn observe_external_configuration(
    container: &ObservedContainer,
    classification: Classification,
    probe_budget: &mut usize,
) -> ExternalConfiguration {
    if classification.ownership == "spark_managed"
        || classification.kind != "inference_engine"
        || container.state != "running"
    {
        return ExternalConfiguration::not_applicable();
    }

    let mut ports: Vec<u16> = container
        .ports
        .iter()
        .filter(|port| port.protocol == "tcp")
        .map(|port| port.host_port)
        .collect();
    ports.sort_unstable();
    ports.dedup();
    // Prefer the engine defaults before any other published service port.
    let preferred = match classification.engine {
        "vllm" => [8000_u16, 30000_u16],
        "sglang" => [30000_u16, 8000_u16],
        _ => [8000_u16, 30000_u16],
    };
    ports.sort_by_key(|port| {
        preferred
            .iter()
            .position(|preferred| preferred == port)
            .unwrap_or(preferred.len())
    });
    ports.truncate(MAX_MODEL_PROBE_PORTS.min(*probe_budget));
    if ports.is_empty() {
        return ExternalConfiguration::unavailable();
    }

    let Ok(client) = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(std::time::Duration::from_millis(250))
        .timeout(std::time::Duration::from_millis(500))
        .build()
    else {
        return ExternalConfiguration::unavailable();
    };

    let mut verified: Option<(u16, Vec<String>)> = None;
    for port in ports {
        *probe_budget = probe_budget.saturating_sub(1);
        let Some(models) = probe_openai_models(&client, port).await else {
            continue;
        };
        if let Some((_, existing)) = &verified {
            if existing != &models {
                return ExternalConfiguration::ambiguous();
            }
        } else {
            verified = Some((port, models));
        }
    }
    match verified {
        Some((port, served_models)) => ExternalConfiguration {
            state: "verified",
            api_protocol: Some("openai_compatible"),
            api_port: Some(port),
            served_models,
        },
        None => ExternalConfiguration::unavailable(),
    }
}

pub(super) async fn probe_openai_models(
    client: &reqwest::Client,
    port: u16,
) -> Option<Vec<String>> {
    let response = client
        .get(format!("http://127.0.0.1:{port}/v1/models"))
        .send()
        .await
        .ok()?;
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > MAX_MODEL_PROBE_BYTES as u64)
    {
        return None;
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.ok()?;
        if bytes.len().saturating_add(chunk.len()) > MAX_MODEL_PROBE_BYTES {
            return None;
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    if value.get("object").and_then(Value::as_str) != Some("list") {
        return None;
    }
    let entries = value.get("data")?.as_array()?;
    if entries.len() > MAX_SERVED_MODELS {
        return None;
    }
    let mut models = Vec::with_capacity(entries.len());
    for entry in entries {
        if entry.get("object").and_then(Value::as_str) != Some("model") {
            return None;
        }
        let model = entry.get("id")?.as_str()?;
        if !readable_model_alias(model) {
            return None;
        }
        models.push(model.to_owned());
    }
    models.sort();
    models.dedup();
    Some(models)
}

pub(super) fn readable_model_alias(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 240
        && !value.contains("..")
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '/' | '.' | '_' | '-' | ':')
        })
}

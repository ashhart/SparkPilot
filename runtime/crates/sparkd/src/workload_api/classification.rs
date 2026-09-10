use super::*;

/// Pair ownership states with the presentation facts needed to distinguish them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Classification {
    pub(super) ownership: &'static str,
    pub(super) kind: &'static str,
    pub(super) engine: &'static str,
    pub(super) management_origin: Option<&'static str>,
}

/// Establish managed ownership from durable runtime ids rather than container names alone.
#[derive(Debug, Default)]
pub(super) struct ManagedIds {
    pub(super) engines: std::collections::HashSet<uuid::Uuid>,
    pub(super) worktrees: std::collections::HashSet<uuid::Uuid>,
    pub(super) adopted_containers: std::collections::HashSet<String>,
}

/// Use recorded engine/worktree ids as restart-stable ownership evidence for reconciliation.
pub(super) fn managed_ids(database: &parking_lot::Mutex<rusqlite::Connection>) -> ManagedIds {
    let connection = database.lock();
    let read = |sql: &str| -> std::collections::HashSet<uuid::Uuid> {
        let Ok(mut statement) = connection.prepare(sql) else {
            return Default::default();
        };
        let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(0)) else {
            return Default::default();
        };
        rows.filter_map(Result::ok)
            .filter_map(|id| uuid::Uuid::parse_str(&id).ok())
            .collect()
    };
    let adopted_containers = connection
        .prepare(
            "SELECT container_id FROM inference_instances WHERE container_id IS NOT NULL AND state != 'stopped' AND json_extract(metadata_json, '$.ownership_origin') = 'external_adoption'",
        )
        .and_then(|mut statement| {
            statement
                .query_map([], |row| row.get::<_, String>(0))
                .map(|rows| rows.filter_map(Result::ok).collect())
        })
        .unwrap_or_default();
    ManagedIds {
        engines: read("SELECT id FROM inference_instances"),
        worktrees: read("SELECT id FROM project_worktrees"),
        adopted_containers,
    }
}

/// Require durable ownership for generated container ids; only the fixed Open WebUI service name has a dedicated name-based rule.
pub(super) fn managed_classification(name: &str, managed: &ManagedIds) -> Option<Classification> {
    if let Some(rest) = name.strip_prefix(MANAGED_ENGINE_PREFIX) {
        let id = uuid::Uuid::parse_str(rest).ok()?;
        return managed.engines.contains(&id).then_some(Classification {
            ownership: "spark_managed",
            kind: "inference_engine",
            // Derive the engine label from the image, not the managed container's name.
            engine: "none",
            management_origin: Some("spark_started"),
        });
    }
    if let Some(rest) = name.strip_prefix(MANAGED_PROJECT_PREFIX) {
        let id = uuid::Uuid::parse_str(rest).ok()?;
        return managed.worktrees.contains(&id).then_some(Classification {
            ownership: "spark_managed",
            kind: "project_container",
            engine: "none",
            management_origin: Some("spark_started"),
        });
    }
    let service = if name == spark_privd::backend::OPEN_WEBUI_CONTAINER
        || name == spark_privd::backend::OPEN_WEBUI_BOOTSTRAP_CONTAINER
    {
        "open_webui"
    } else if name == spark_privd::kokoro::CONTAINER {
        "kokoro"
    } else if name == spark_privd::searxng::CONTAINER {
        "searxng"
    } else {
        return None;
    };
    // Every optional service the helper starts has a fixed name; none of them serve inference.
    Some(Classification {
        ownership: "spark_managed",
        kind: "optional_service",
        engine: service,
        management_origin: Some("spark_started"),
    })
}

/// Recognize whole image repository segments for advisory labels only; recognition never grants lifecycle authority.
pub(super) const RECOGNISED_SEGMENTS: [(&str, &str, &str); 11] = [
    ("vllm", "inference_engine", "vllm"),
    ("vllm-openai", "inference_engine", "vllm"),
    ("sglang", "inference_engine", "sglang"),
    ("open-webui", "optional_service", "open_webui"),
    ("openwebui", "optional_service", "open_webui"),
    ("kokoro-fastapi-gpu", "optional_service", "kokoro"),
    ("kokoro-fastapi-cpu", "optional_service", "kokoro"),
    ("searxng", "optional_service", "searxng"),
    ("ray", "cluster_runtime", "ray"),
    ("ray-ml", "cluster_runtime", "ray"),
    ("rayproject", "cluster_runtime", "ray"),
];

pub(super) fn recognise_image(image: &str) -> Option<Classification> {
    repository_path(image)
        .split('/')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .find_map(|segment| {
            let segment = segment.to_ascii_lowercase();
            RECOGNISED_SEGMENTS
                .iter()
                .find(|(marker, _, _)| *marker == segment)
                .map(|(_, kind, engine)| Classification {
                    ownership: "external_observed",
                    kind,
                    engine,
                    management_origin: None,
                })
        })
}

/// Strip tags/digests before engine recognition so an unrelated image tagged ray is not classified as Ray.
pub(super) fn repository_path(image: &str) -> &str {
    let path = image.split('@').next().unwrap_or(image);
    // Treat colons after the last slash as tags and earlier colons as registry ports.
    match path.rfind(':') {
        Some(index) if index > path.rfind('/').map_or(0, |slash| slash) => &path[..index],
        _ => path,
    }
}

pub(super) fn classify(container: &ObservedContainer, managed: &ManagedIds) -> Classification {
    let recognised = container.image.as_deref().and_then(recognise_image);
    if managed.adopted_containers.contains(&container.id) {
        return Classification {
            ownership: "spark_managed",
            kind: "inference_engine",
            engine: recognised.map_or("none", |image| image.engine),
            management_origin: Some("external_adoption"),
        };
    }
    if let Some(owned) = container
        .name
        .as_deref()
        .and_then(|name| managed_classification(name, managed))
    {
        // Use durable records for ownership/kind and the observed image for engine identity.
        return Classification {
            engine: match owned.engine {
                "none" => recognised.map_or("none", |image| image.engine),
                declared => declared,
            },
            ..owned
        };
    }
    if let Some(recognised) = recognised {
        return recognised;
    }
    Classification {
        ownership: "unknown_external",
        kind: "unknown",
        engine: "none",
        management_origin: None,
    }
}

pub(super) fn present(
    container: &ObservedContainer,
    classification: Classification,
    configuration: ExternalConfiguration,
) -> Value {
    let ports: Vec<Value> = container
        .ports
        .iter()
        .map(|port| {
            json!({
                "host_ip": port.host_ip,
                "host_port": port.host_port,
                "container_port": port.container_port,
                "protocol": port.protocol,
            })
        })
        .collect();
    json!({
        "workload_id": container.id,
        "name": container.name,
        "ownership": classification.ownership,
        "kind": classification.kind,
        "recognised_engine": classification.engine,
        "management_origin": classification.management_origin,
        "state": container.state,
        "image_reference": container.image,
        "published_ports": ports,
        "configuration_state": configuration.state,
        "api_protocol": configuration.api_protocol,
        "api_port": configuration.api_port,
        "served_models": configuration.served_models,
    })
}

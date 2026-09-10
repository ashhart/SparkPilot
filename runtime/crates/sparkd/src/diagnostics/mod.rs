//! Build support bundles from allowlisted fields and explicit sensitivity choices; see docs/development/runtime-data-boundaries.md.

mod collect;
mod logs;
mod manifest;
mod policy;

use std::collections::BTreeSet;

use serde_json::{Value, json};

pub use manifest::{Bundle, BundleFile, Manifest, ManifestEntry};
pub use policy::{
    DEFAULT_SECTIONS, Exclusion, NEVER_EXPORTED, OPTIONAL_SECTIONS, SectionSpec, Sensitivity,
    UnknownCategory, resolve_selection,
};

use crate::crypto::sha256_hex;
use crate::state::AppState;

/// Fixed reason codes. The underlying error text never reaches a bundle.
pub(crate) const NO_DATABASE: &str = "NO_DATABASE";
pub(crate) const SECTION_QUERY_FAILED: &str = "SECTION_QUERY_FAILED";
pub(crate) const NETWORK_INVENTORY_UNAVAILABLE: &str = "NETWORK_INVENTORY_UNAVAILABLE";
pub(crate) const INTEGRITY_CHECK_FAILED: &str = "INTEGRITY_CHECK_FAILED";
pub(crate) const AUDIT_CHAIN_UNREADABLE: &str = "AUDIT_CHAIN_UNREADABLE";
pub(crate) const NO_PRIVILEGED_BOUNDARY: &str = "NO_PRIVILEGED_BOUNDARY";
pub(crate) const NO_ACTIVE_ENGINE: &str = "NO_ACTIVE_ENGINE";
pub(crate) const OS_RELEASE_UNREADABLE: &str = "OS_RELEASE_UNREADABLE";
pub(crate) const DRIVER_VERSION_UNREADABLE: &str = "DRIVER_VERSION_UNREADABLE";
const RENDER_FAILED: &str = "RENDER_FAILED";

/// A section that could not be collected, stated as a code.
pub(crate) fn unavailable_code(reason_code: &'static str) -> Value {
    json!({ "available": false, "reason_code": reason_code })
}

/// Build the bundle for one export.
pub async fn build(state: &AppState, selected: &BTreeSet<&'static str>) -> Bundle {
    let included: Vec<&SectionSpec> = DEFAULT_SECTIONS
        .iter()
        .chain(
            OPTIONAL_SECTIONS
                .iter()
                .filter(|spec| selected.contains(spec.id)),
        )
        .collect();

    let mut files = Vec::with_capacity(included.len());
    for spec in &included {
        files.push(render(spec, content(state, spec.id).await));
    }

    let entries = files
        .iter()
        .zip(included.iter())
        .map(|(file, spec)| ManifestEntry {
            path: file.path.clone(),
            sensitivity: file.sensitivity,
            description: spec.description,
            bytes: file.content.len(),
            sha256: sha256_hex(file.content.as_bytes()),
        })
        .collect();

    Bundle {
        manifest: Manifest {
            schema: 1,
            generated_at: state.clock.now_rfc3339(),
            node_id: state.identity.public.node_id.to_string(),
            runtime_version: state.config.runtime_version.clone(),
            files: entries,
            optional_included: OPTIONAL_SECTIONS
                .iter()
                .filter(|spec| selected.contains(spec.id))
                .map(|spec| spec.id)
                .collect(),
            optional_excluded: OPTIONAL_SECTIONS
                .iter()
                .filter(|spec| !selected.contains(spec.id))
                .map(|spec| spec.id)
                .collect(),
            never_exported: NEVER_EXPORTED,
        },
        files,
    }
}

fn render(spec: &SectionSpec, content: Value) -> BundleFile {
    BundleFile {
        // Derive filenames only from separator-free compile-time section IDs.
        path: format!("{}.json", spec.id),
        sensitivity: spec.sensitivity.name(),
        content: serde_json::to_string_pretty(&content)
            .unwrap_or_else(|_| unavailable_code(RENDER_FAILED).to_string()),
    }
}

async fn content(state: &AppState, id: &str) -> Value {
    match id {
        "runtime" => collect::runtime_section(state),
        "host" => collect::host_section(state),
        "services" => collect::services_section(state),
        "logs" => logs::logs_section(state).await,
        "operations" => collect::operations_section(state),
        "events" => collect::events_section(state),
        "memory-pressure" => collect::memory_pressure_section(state),
        "models" => collect::models_section(state),
        "network" => collect::network_section(state, false).await,
        "cluster" => collect::cluster_section(state),
        "database" => collect::database_section(state),
        "audit" => collect::audit_section(state),
        "network-addresses" => collect::network_section(state, true).await,
        "host-paths" => collect::host_paths_section(state),
        // Report unexpected section failures as fixed codes without echoing IDs.
        _ => unavailable_code(RENDER_FAILED),
    }
}

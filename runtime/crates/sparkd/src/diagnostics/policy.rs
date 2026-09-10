//! Declare each export section's sensitivity and default in one policy table.

use std::collections::BTreeSet;

use serde::Serialize;

/// Sensitivity of the installation information an entry may reveal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Sensitivity {
    /// Host and runtime facts that name no person, address or secret.
    Operational,
    /// Owner-identifying installation facts, including hostnames, addresses and filesystem paths.
    Identifying,
}

impl Sensitivity {
    pub fn name(self) -> &'static str {
        match self {
            Sensitivity::Operational => "operational",
            Sensitivity::Identifying => "identifying",
        }
    }
}

/// One section of the bundle, described to the owner before they export.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct SectionSpec {
    pub id: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    pub sensitivity: Sensitivity,
    pub included_by_default: bool,
}

/// Describe intentionally excluded content so its absence is explicit.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct Exclusion {
    pub id: &'static str,
    pub title: &'static str,
    pub reason: &'static str,
}

const fn section(id: &'static str, title: &'static str, description: &'static str) -> SectionSpec {
    SectionSpec {
        id,
        title,
        description,
        sensitivity: Sensitivity::Operational,
        included_by_default: true,
    }
}

const fn optional(id: &'static str, title: &'static str, description: &'static str) -> SectionSpec {
    SectionSpec {
        id,
        title,
        description,
        sensitivity: Sensitivity::Identifying,
        included_by_default: false,
    }
}

/// Default operational sections covered by the category-completeness test.
pub const DEFAULT_SECTIONS: &[SectionSpec] = &[
    section(
        "runtime",
        "Runtime version and configuration",
        "Runtime version, API major version, transport mode and advertisement setting. Configuration secrets are not part of this record.",
    ),
    section(
        "host",
        "Host, driver, container runtime and hardware",
        "DGX OS release, accelerator and driver versions, the container runtime this build detected, unified memory totals, load, storage headroom and thermal state.",
    ),
    section(
        "services",
        "Service health",
        "Observed engine state, memory-guard pressure, cluster state, container-runtime availability and remote-access posture, rather than which services were compiled in.",
    ),
    section(
        "logs",
        "Bounded service logs",
        "Metadata projected from the last lines of the sparkd, spark-privd and engine logs, and the recorded stages of the most recent operations. Log message text is never included.",
    ),
    section(
        "operations",
        "Recent durable operations",
        "The most recent operations by kind, state, timing and failure code. Operation inputs and results are not included.",
    ),
    section(
        "events",
        "Recent runtime events",
        "The most recent event types, severities and times. Event payloads are not included.",
    ),
    section(
        "memory-pressure",
        "Memory-pressure timeline",
        "Recorded pressure transitions with the available memory and the reason for each change.",
    ),
    section(
        "models",
        "Model recipes and profiles",
        "Installed model identifiers with recipe revisions and digests, and every profile identifier with its expected and measured peaks.",
    ),
    section(
        "network",
        "Network interfaces",
        "Interface names, types, link states and speeds, with addresses reduced to a count and an address family.",
    ),
    section(
        "cluster",
        "Cluster health and validation tests",
        "Cluster state and membership as this node last observed it, with the outcome of the most recent link and collective validation runs.",
    ),
    section(
        "database",
        "Database schema and integrity",
        "Applied schema version, the result of SQLite's own integrity check, and the row count of each table.",
    ),
    section(
        "audit",
        "Audit chain integrity",
        "The highest audit sequence and whether the hash chain verifies. Audit record contents are not included.",
    ),
];

/// Include sensitive categories only when the owner selects them for this export.
pub const OPTIONAL_SECTIONS: &[SectionSpec] = &[
    optional(
        "network-addresses",
        "Full network addresses",
        "Unreduced IPv4 and IPv6 addresses, gateway, DNS servers, MAC addresses and the joined Wi-Fi network name.",
    ),
    optional(
        "host-paths",
        "Full filesystem paths",
        "The runtime data directory and the model and download directories beneath it.",
    ),
];

/// Categories no control can ever include.
pub const NEVER_EXPORTED: &[Exclusion] = &[
    Exclusion {
        id: "prompts",
        title: "Prompts and responses",
        reason: "Prompt and response text is not retained by the runtime (ADR-017), and no section reads an operation's input or result.",
    },
    Exclusion {
        id: "project-files",
        title: "Project file contents",
        reason: "Project working trees belong to the project, not to a support bundle. No section reads a worktree.",
    },
    Exclusion {
        id: "private-keys",
        title: "Private keys and SSH material",
        reason: "Node and device private key material is never read by this composition and never leaves its store.",
    },
    Exclusion {
        id: "provider-tokens",
        title: "Provider access tokens",
        reason: "Hugging Face and other provider secrets live in protected files the runtime references but does not read here; the credential table is not queried at all rather than being queried and redacted.",
    },
    Exclusion {
        id: "remote-address",
        title: "Tunnel credentials and hostnames",
        reason: "The published private hostname is never read; only whether remote access is enabled, its mode and its health appear.",
    },
];

/// An optional category the owner named that this build does not offer.
#[derive(Debug, PartialEq, Eq)]
pub struct UnknownCategory(pub String);

/// Reject unknown category IDs instead of silently omitting requested content.
pub fn resolve_selection(requested: &[String]) -> Result<BTreeSet<&'static str>, UnknownCategory> {
    let mut selected = BTreeSet::new();
    for id in requested {
        match OPTIONAL_SECTIONS
            .iter()
            .find(|section| section.id == id.as_str())
        {
            Some(section) => {
                selected.insert(section.id);
            }
            None => return Err(UnknownCategory(id.clone())),
        }
    }
    Ok(selected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_section_id_is_a_flat_archive_name() {
        for spec in DEFAULT_SECTIONS.iter().chain(OPTIONAL_SECTIONS) {
            let path = format!("{}.json", spec.id);
            assert!(
                crate::beneath::safe_components(&path).is_ok(),
                "{path} is not a safe archive-relative path"
            );
            assert!(!spec.id.contains('/'), "{} is not flat", spec.id);
        }
    }

    #[test]
    fn section_ids_are_unique_across_both_lists() {
        let mut seen = BTreeSet::new();
        for spec in DEFAULT_SECTIONS.iter().chain(OPTIONAL_SECTIONS) {
            assert!(seen.insert(spec.id), "{} is declared twice", spec.id);
        }
    }

    /// Preserve every required default diagnostic category.
    #[test]
    fn plan_46_1_categories_are_all_present() {
        let ids: BTreeSet<&str> = DEFAULT_SECTIONS.iter().map(|spec| spec.id).collect();
        for required in [
            "runtime",
            "host",
            "services",
            "logs",
            "operations",
            "events",
            "memory-pressure",
            "models",
            "network",
            "cluster",
            "database",
            "audit",
        ] {
            assert!(
                ids.contains(required),
                "§46.1 category {required} is missing"
            );
        }
    }

    #[test]
    fn no_optional_category_is_on_by_default() {
        for spec in OPTIONAL_SECTIONS {
            assert!(!spec.included_by_default);
            assert_eq!(spec.sensitivity, Sensitivity::Identifying);
        }
        for spec in DEFAULT_SECTIONS {
            assert!(spec.included_by_default);
            assert_eq!(spec.sensitivity, Sensitivity::Operational);
        }
    }

    #[test]
    fn a_never_exported_category_cannot_be_selected() {
        for exclusion in NEVER_EXPORTED {
            assert_eq!(
                resolve_selection(&[exclusion.id.to_owned()]),
                Err(UnknownCategory(exclusion.id.to_owned())),
                "{} is selectable",
                exclusion.id
            );
        }
    }
}

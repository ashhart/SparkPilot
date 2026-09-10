//! Derive the bundle manifest from produced files so every archive entry has a manifest record.

use serde::Serialize;

use super::policy::Exclusion;

/// Build flat archive names only from compile-time section IDs without separators.
#[derive(Debug, Clone, Serialize)]
pub struct BundleFile {
    pub path: String,
    pub sensitivity: &'static str,
    pub content: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestEntry {
    pub path: String,
    pub sensitivity: &'static str,
    pub description: &'static str,
    pub bytes: usize,
    pub sha256: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Manifest {
    pub schema: u32,
    pub generated_at: String,
    pub node_id: String,
    pub runtime_version: String,
    pub files: Vec<ManifestEntry>,
    pub optional_included: Vec<&'static str>,
    pub optional_excluded: Vec<&'static str>,
    pub never_exported: &'static [Exclusion],
}

#[derive(Debug, Clone, Serialize)]
pub struct Bundle {
    pub manifest: Manifest,
    pub files: Vec<BundleFile>,
}

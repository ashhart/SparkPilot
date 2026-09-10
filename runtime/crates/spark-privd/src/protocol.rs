//! Versioned privileged operations with validated fields and bounded responses; no arbitrary command or file-write requests.

use std::collections::VecDeque;

use std::io::{Read, Write};

use std::net::Ipv4Addr;

use serde::{Deserialize, Serialize};

use sha2::{Digest, Sha256};

use thiserror::Error;

use uuid::Uuid;

/// Maximum request size in bytes.
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;

/// Maximum response size in bytes.
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;

/// Dedicated member-authentication port admitted only on the fenced CX-7 path.
pub const CLUSTER_FABRIC_CHALLENGE_PORT: u16 = 19_443;

/// Header length for length-delimited framing.
const FRAME_HEADER_BYTES: usize = 4;

/// Bound retained IDs even during a request flood.
const DUPLICATE_WINDOW: usize = 8192;

/// Retain request IDs for one hour to reject retries without unbounded storage.
const DUPLICATE_RETENTION: std::time::Duration = std::time::Duration::from_secs(3600);

/// Allowed operations carry request IDs for duplicate rejection.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum KokoroAction {
    Enable,
    Disable,
    Status,
    Install,
    Update,
    Remove,
}

/// What the owner asked of the Spark's own search service.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SearxngAction {
    Install,
    Status,
    Remove,
}

/// Prepare an inactive owned link, commit its activation, or remove it during rollback.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClusterLinkPhase {
    Prepare,
    Commit,
    Rollback,
}

/// Sort member IDs before hashing so every member derives the same execution identity.
#[derive(Debug, Clone, Copy)]
pub struct ClusterExecutionDigestInput<'a> {
    pub cluster_id: Uuid,
    pub launch_id: Uuid,
    pub local_node_id: Uuid,
    pub peer_node_id: Uuid,
    pub coordinator_node_id: Uuid,
    pub recipe_id: &'a str,
    pub profile_id: &'a str,
    pub recipe_digest: &'a str,
    pub image_digest: &'a str,
    pub served_name: &'a str,
    pub model_snapshot: &'a str,
    pub host_port: u16,
    pub gpu_memory_utilisation_milli: u16,
    pub max_model_length: u64,
    pub max_sequences: u32,
    pub max_batched_tokens: u64,
    pub tensor_parallel_size: u8,
}

/// NUL-delimit digest fields and reject embedded NULs before hashing caller-controlled values.
pub fn cluster_execution_digest(input: ClusterExecutionDigestInput<'_>) -> String {
    let mut members = [input.local_node_id, input.peer_node_id];
    members.sort();
    let fields = [
        "sparkpilot-cluster-execution-v1".to_owned(),
        input.cluster_id.to_string(),
        input.launch_id.to_string(),
        members[0].to_string(),
        members[1].to_string(),
        input.coordinator_node_id.to_string(),
        input.recipe_id.to_owned(),
        input.profile_id.to_owned(),
        input.recipe_digest.to_owned(),
        input.image_digest.to_owned(),
        input.served_name.to_owned(),
        input.model_snapshot.to_owned(),
        input.host_port.to_string(),
        input.gpu_memory_utilisation_milli.to_string(),
        input.max_model_length.to_string(),
        input.max_sequences.to_string(),
        input.max_batched_tokens.to_string(),
        input.tensor_parallel_size.to_string(),
    ];
    let canonical = fields.join("\0");
    format!("{:x}", Sha256::digest(canonical.as_bytes()))
}

/// Log sources authorized for diagnostics.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "log", rename_all = "snake_case")]
pub enum LogSource {
    Sparkd,
    SparkPrivd,
    /// The engine container this runtime started for one inference instance.
    Engine {
        instance_id: Uuid,
    },
}

impl LogSource {
    /// Stable name used in the bundle and in helper audit records.
    pub fn name(self) -> &'static str {
        match self {
            LogSource::Sparkd => "sparkd",
            LogSource::SparkPrivd => "spark-privd",
            LogSource::Engine { .. } => "engine",
        }
    }

    /// Return fixed systemd units without caller-supplied fragments.
    pub fn systemd_unit(self) -> Option<&'static str> {
        match self {
            LogSource::Sparkd => Some("sparkd.service"),
            LogSource::SparkPrivd => Some("spark-privd.service"),
            LogSource::Engine { .. } => None,
        }
    }
}

/// Hard ceiling on a diagnostic log tail, applied inside the helper.
pub const MAX_DIAGNOSTIC_LOG_LINES: u32 = 200;

/// Hard ceiling on the bytes one log tail may return.
pub const MAX_DIAGNOSTIC_LOG_BYTES: usize = 32 * 1024;

/// Transport secrets over the authenticated socket without exposing them in Debug, errors, responses or Docker arguments.
#[derive(
    Clone, Serialize, Deserialize, PartialEq, Eq, zeroize::Zeroize, zeroize::ZeroizeOnDrop,
)]
#[serde(transparent)]
pub struct SecretString(String);

impl SecretString {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn expose_secret(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for SecretString {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("<redacted>")
    }
}

/// Map a closed terminal-shell enum to fixed arguments so requests cannot introduce arbitrary command strings.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalShell {
    /// The container's POSIX login shell.
    Login,
    /// Bash, where the image provides it.
    Bash,
    /// An interactive Python REPL.
    Python,
    /// Runtime-configured coding harness inside the managed development container.
    Development,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "tool", rename_all = "snake_case")]
pub enum ProjectToolOperation {
    ReadFile { path: String },
    SearchFiles { path: String, pattern: String },
    WriteFile { path: String, content: SecretString },
    DeleteFile { path: String },
    RunCommand { argv: Vec<String> },
    Git { operation: ProjectGitOperation },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "operation", rename_all = "snake_case")]
pub enum ProjectGitOperation {
    Status,
    Diff,
    DiffStat,
    Log { count: u8 },
    Add { path: String },
    Commit { message: String },
}

impl TerminalShell {
    /// Argv executed inside the container. Constant by construction.
    pub fn argv(self) -> &'static [&'static str] {
        match self {
            TerminalShell::Login => &["/bin/sh", "-l"],
            TerminalShell::Bash => &["/bin/bash", "-l"],
            TerminalShell::Python => &["/usr/bin/env", "python3", "-i"],
            TerminalShell::Development => {
                &["/usr/bin/env", "node", "/workspace/.spark-pilot-launch.cjs"]
            }
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            TerminalShell::Login => "login",
            TerminalShell::Bash => "bash",
            TerminalShell::Python => "python",
            TerminalShell::Development => "development",
        }
    }

    /// Reject unknown names instead of silently opening a different shell.
    pub fn parse(value: &str) -> Option<TerminalShell> {
        match value {
            "login" => Some(TerminalShell::Login),
            "bash" => Some(TerminalShell::Bash),
            "python" => Some(TerminalShell::Python),
            "development" => Some(TerminalShell::Development),
            _ => None,
        }
    }
}

/// Require spark-project-<uuid> so terminal access cannot target unrelated containers.
pub fn valid_project_container_id(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("spark-project-") else {
        return false;
    };
    Uuid::parse_str(rest).is_ok()
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BluetoothAction {
    PowerOn,
    PowerOff,
    StartDiscovery,
    StopDiscovery,
    Pair,
    Remove,
}

/// Bounded structured response.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivilegedResponse {
    pub request_id: Uuid,
    pub accepted: bool,
    pub code: String,
    pub message: String,
    pub details: serde_json::Value,
}

impl PrivilegedResponse {
    pub fn ok(request_id: Uuid, code: &str, message: &str) -> Self {
        Self {
            request_id,
            accepted: true,
            code: code.to_owned(),
            message: message.to_owned(),
            details: serde_json::Value::Null,
        }
    }

    pub fn rejected(request_id: Uuid, code: &str, message: &str) -> Self {
        Self {
            request_id,
            accepted: false,
            code: code.to_owned(),
            message: message.to_owned(),
            details: serde_json::Value::Null,
        }
    }
}

/// Map verified recipe options to fixed flags, rejecting values outside the helper allowlist.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct EngineLaunchOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preparation: Option<String>,
    /// vLLM `--mamba-cache-mode`: `none`, `align` or `all`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mamba_cache_mode: Option<String>,
    /// vLLM `--kv-cache-dtype`: `auto` or `fp8`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kv_cache_dtype: Option<String>,
    /// vLLM `--reasoning-parser`: one of the named formats below.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_parser: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_parser: Option<String>,
}

impl EngineLaunchOptions {
    pub const MAMBA_CACHE_MODES: &'static [&'static str] = &["none", "align", "all"];
    pub const KV_CACHE_DTYPES: &'static [&'static str] = &["auto", "fp8"];
    pub const REASONING_PARSERS: &'static [&'static str] = &[
        "nemotron_v3",
        "deepseek_r1",
        "qwen3",
        "granite",
        "glm45",
        "openai_gptoss",
    ];

    /// Return fixed flags or the first rejected option value.
    pub fn launch_flags(&self) -> Result<Vec<String>, String> {
        let mut flags = Vec::new();
        if let Some(preparation) = &self.preparation
            && preparation != "qwen38_78b0675"
        {
            return Err("unknown engine preparation".into());
        }
        if let Some(mode) = &self.mamba_cache_mode {
            if !Self::MAMBA_CACHE_MODES.contains(&mode.as_str()) {
                return Err(format!("mamba cache mode {mode:?} is not allowed"));
            }
            flags.push("--mamba-cache-mode".to_owned());
            flags.push(mode.clone());
        }
        if let Some(dtype) = &self.kv_cache_dtype {
            if !Self::KV_CACHE_DTYPES.contains(&dtype.as_str()) {
                return Err(format!("KV cache dtype {dtype:?} is not allowed"));
            }
            flags.push("--kv-cache-dtype".to_owned());
            flags.push(dtype.clone());
        }
        if let Some(parser) = &self.reasoning_parser {
            if !Self::REASONING_PARSERS.contains(&parser.as_str()) {
                return Err(format!("reasoning parser {parser:?} is not allowed"));
            }
            flags.push("--reasoning-parser".to_owned());
            flags.push(parser.clone());
        }
        if let Some(parser) = &self.tool_call_parser {
            if parser != "qwen3_coder" {
                return Err(format!("tool call parser {parser:?} is not allowed"));
            }
            flags.push("--enable-auto-tool-choice".to_owned());
            flags.push("--tool-call-parser".to_owned());
            flags.push(parser.clone());
        }
        Ok(flags)
    }
}

/// Validate identifiers before backend execution.
pub const RECIPE_ID_PATTERN: &str = r"^[a-z0-9][a-z0-9._/-]{1,239}$";

pub const PROFILE_ID_PATTERN: &str = r"^[a-z0-9][a-z0-9._-]{1,79}$";

pub fn valid_recipe_id(id: &str) -> bool {
    regex_lite_ish_matches(RECIPE_ID_PATTERN, id)
}

pub fn valid_profile_id(id: &str) -> bool {
    regex_lite_ish_matches(PROFILE_ID_PATTERN, id)
}

/// Accept one lowercase RFC 1123 hostname label because this changes a local machine name, not a DNS zone.
pub fn valid_system_hostname(hostname: &str) -> bool {
    let bytes = hostname.as_bytes();
    (1..=63).contains(&bytes.len())
        && bytes
            .first()
            .is_some_and(|value| value.is_ascii_lowercase() || value.is_ascii_digit())
        && bytes
            .last()
            .is_some_and(|value| value.is_ascii_lowercase() || value.is_ascii_digit())
        && bytes
            .iter()
            .all(|value| value.is_ascii_lowercase() || value.is_ascii_digit() || *value == b'-')
}

/// Reject unusable LAN hosts, off-link gateways, reserved subnets and invalid DNS lists before NetworkManager sees them.
pub fn valid_lan_ipv4(
    address: Ipv4Addr,
    prefix_length: u8,
    gateway: Ipv4Addr,
    dns_servers: &[Ipv4Addr],
) -> bool {
    if !(1..=30).contains(&prefix_length)
        || !usable_ipv4(address)
        || !usable_ipv4(gateway)
        || address == gateway
        || !(1..=3).contains(&dns_servers.len())
        || dns_servers.iter().any(|server| !resolvable_ipv4(*server))
        || dns_servers
            .iter()
            .enumerate()
            .any(|(index, server)| dns_servers[..index].contains(server))
        || sparkpilot_owned_subnet(address)
    {
        return false;
    }
    let mask = u32::MAX << (32 - prefix_length);
    let address_bits = u32::from(address);
    let gateway_bits = u32::from(gateway);
    let network = address_bits & mask;
    let broadcast = network | !mask;
    address_bits != network
        && address_bits != broadcast
        && gateway_bits != network
        && gateway_bits != broadcast
        && gateway_bits & mask == network
}

fn usable_ipv4(address: Ipv4Addr) -> bool {
    !address.is_unspecified()
        && !address.is_loopback()
        && !address.is_link_local()
        && !address.is_multicast()
        && address != Ipv4Addr::BROADCAST
}

fn resolvable_ipv4(address: Ipv4Addr) -> bool {
    !address.is_unspecified() && !address.is_multicast() && address != Ipv4Addr::BROADCAST
}

fn sparkpilot_owned_subnet(address: Ipv4Addr) -> bool {
    let octets = address.octets();
    octets[0..3] == [192, 168, 251] || octets[0..3] == [192, 168, 252]
}

/// Digest-pinned container image (`registry/repo@sha256:<64 hex>`).
pub fn valid_pinned_image(image: &str) -> bool {
    let Some((repository, digest)) = image.rsplit_once('@') else {
        return false;
    };
    let hex = digest.strip_prefix("sha256:").unwrap_or_default();
    !repository.is_empty()
        && !repository.starts_with('-')
        && repository.len() <= 512
        && !repository.chars().any(char::is_whitespace)
        && hex.len() == 64
        && hex
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
        && hex.chars().any(|c| c != '0')
}

/// Match the two identifier character classes without adding a regex dependency.
fn regex_lite_ish_matches(pattern: &str, value: &str) -> bool {
    match pattern {
        RECIPE_ID_PATTERN => {
            !value.is_empty()
                && value.len() <= 240
                && value
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
                && value.chars().all(|c| {
                    c.is_ascii_lowercase()
                        || c.is_ascii_digit()
                        || matches!(c, '.' | '_' | '/' | '-')
                })
        }
        PROFILE_ID_PATTERN => {
            !value.is_empty()
                && value.len() <= 80
                && value
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
                && value.chars().all(|c| {
                    c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-')
                })
        }
        _ => false,
    }
}

#[cfg(test)]
#[path = "protocol/tests.rs"]
mod tests;

mod operations;
pub use operations::PrivilegedOperation;

mod framing;
pub use framing::{
    ProtocolError, RequestIdTracker, parse_request, read_request, read_response,
    read_response_with_fd, write_request, write_response, write_response_with_fd,
};

/// The private service listener; browser access continues through the Spark's TLS proxy.
pub const fn default_open_webui_port() -> u16 {
    18080
}

pub fn valid_open_webui_port(port: u16) -> bool {
    port >= 1024 && !matches!(port, 7443 | 7444 | 18081 | 18100..=18199)
}

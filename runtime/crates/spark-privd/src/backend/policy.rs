use super::*;

#[derive(Debug, Error)]
pub enum BackendError {
    #[error("invalid operation input: {0}")]
    InvalidInput(String),
    #[error("backend failure: {0}")]
    Failure(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

/// Privileged execution boundary with deterministic substitutes for hardware and process effects.
pub trait OpBackend: Send + Sync {
    fn execute(&self, op: &PrivilegedOperation) -> Result<PrivilegedResponse, BackendError>;

    /// Operations remain descriptor-free unless a backend explicitly implements descriptor passing.
    fn execute_with_fd(
        &self,
        op: &PrivilegedOperation,
    ) -> Result<(PrivilegedResponse, Option<std::os::fd::OwnedFd>), BackendError> {
        self.execute(op).map(|response| (response, None))
    }
}

pub(super) fn parse_stored_ipv4_addresses(
    value: &str,
) -> Result<Vec<StoredIpv4Address>, BackendError> {
    if value.is_empty() || value == "--" {
        return Ok(Vec::new());
    }
    value
        .split(',')
        .map(|entry| {
            let (address, prefix_length) = entry.trim().split_once('/').ok_or_else(|| {
                BackendError::Failure("NetworkManager returned an invalid IPv4 address".into())
            })?;
            Ok(StoredIpv4Address {
                address: address.parse().map_err(|_| {
                    BackendError::Failure("NetworkManager returned an invalid IPv4 address".into())
                })?,
                prefix_length: prefix_length.parse().map_err(|_| {
                    BackendError::Failure("NetworkManager returned an invalid IPv4 prefix".into())
                })?,
            })
        })
        .collect()
}

pub(super) fn parse_optional_ipv4(value: &str) -> Result<Option<Ipv4Addr>, BackendError> {
    if value.is_empty() || value == "--" {
        return Ok(None);
    }
    value
        .parse()
        .map(Some)
        .map_err(|_| BackendError::Failure("NetworkManager returned an invalid gateway".into()))
}

pub(super) fn parse_ipv4_list(value: &str) -> Result<Vec<Ipv4Addr>, BackendError> {
    if value.is_empty() || value == "--" {
        return Ok(Vec::new());
    }
    value
        .split(',')
        .map(|entry| {
            entry.trim().parse().map_err(|_| {
                BackendError::Failure("NetworkManager returned an invalid DNS server".into())
            })
        })
        .collect()
}

pub(super) struct CredentialGuard(pub(super) PathBuf);

impl Drop for CredentialGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub(super) fn validate_inference_network(network: &serde_json::Value) -> Result<(), BackendError> {
    let options = network
        .get("Options")
        .and_then(serde_json::Value::as_object);
    let option = |name: &str| {
        options
            .and_then(|options| options.get(name))
            .and_then(serde_json::Value::as_str)
    };
    let valid = network.get("Name").and_then(serde_json::Value::as_str)
        == Some(INFERENCE_ISOLATED_NETWORK)
        && network.get("Driver").and_then(serde_json::Value::as_str) == Some("bridge")
        && network.get("Scope").and_then(serde_json::Value::as_str) == Some("local")
        && network.get("Internal").and_then(serde_json::Value::as_bool) == Some(false)
        && network
            .get("Attachable")
            .and_then(serde_json::Value::as_bool)
            == Some(false)
        && network.get("Ingress").and_then(serde_json::Value::as_bool) == Some(false)
        && network
            .get("EnableIPv6")
            .and_then(serde_json::Value::as_bool)
            == Some(false)
        && option("com.docker.network.bridge.enable_ip_masquerade") == Some("false")
        && option("com.docker.network.bridge.enable_icc") == Some("false")
        && option("com.docker.network.bridge.host_binding_ipv4") == Some("127.0.0.1")
        && option("com.docker.network.bridge.trusted_host_interfaces").is_none();
    if valid {
        Ok(())
    } else {
        Err(BackendError::Failure(
            "existing inference network does not satisfy the fixed isolation policy".into(),
        ))
    }
}

pub(super) fn valid_served_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 240
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '/' | '-')
        })
}

pub(super) fn valid_api_key(value: &str) -> bool {
    (32..=256).contains(&value.len())
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '_' | '-'))
}

pub(super) fn valid_open_webui_image(value: &str) -> bool {
    let Some(digest) = value.strip_prefix("ghcr.io/open-webui/open-webui@sha256:") else {
        return false;
    };
    digest.len() == 64
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        && digest.bytes().any(|byte| byte != b'0')
}

pub(super) fn valid_open_webui_admin(email: &str, name: &str, password: &str) -> bool {
    email.len() <= 254
        && email.contains('@')
        && !email.chars().any(char::is_control)
        && (1..=120).contains(&name.len())
        && !name.chars().any(char::is_control)
        && (16..=128).contains(&password.len())
        && !password.chars().any(char::is_control)
}

pub(super) fn docker_reports_missing_container(stderr: &[u8]) -> bool {
    let message = String::from_utf8_lossy(stderr).to_ascii_lowercase();
    message.contains("no such container") || message.contains("no such object")
}

pub(crate) fn valid_ssid(value: &str) -> bool {
    let length = value.len();
    if !(1..=32).contains(&length) || value.chars().any(char::is_control) {
        return false;
    }
    // Reject option-shaped SSIDs because nmcli interprets positional keywords even without a shell.
    if value.starts_with('-') {
        return false;
    }
    // Reserve runtime-owned wired profiles against Wi-Fi mutations.
    !is_reserved_profile(value)
}

/// A NetworkManager profile this runtime owns.
pub(crate) fn is_reserved_profile(value: &str) -> bool {
    value == DIRECT_PROFILE || value == TRAVEL_PROFILE || value.starts_with("SparkPilot-CX7")
}

pub(super) fn valid_wifi_passphrase(value: &str, minimum: usize) -> bool {
    (minimum..=63).contains(&value.len())
        && value.is_ascii()
        && !value.chars().any(char::is_control)
}

pub(super) fn valid_bluetooth_address(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 17
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 2 | 5 | 8 | 11 | 14) {
                *byte == b':'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

pub(super) fn valid_timezone(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.contains('/')
        && value.split('/').all(|component| {
            !component.is_empty()
                && component != "."
                && component != ".."
                && component.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
                })
        })
}

/// The transient unit that carries one OS update job.
pub fn system_update_unit_name(job_id: &str) -> String {
    format!("spark-os-update-{job_id}.service")
}

/// Build fixed systemd arguments for one detached update worker without accepting executable or shell text.
pub fn system_update_worker_argv(
    job_id: &str,
    system_packages: bool,
    firmware: bool,
) -> Vec<String> {
    let unit = system_update_unit_name(job_id);
    let mut argv: Vec<String> = vec![
        "--quiet".into(),
        "--collect".into(),
        "--unit".into(),
        unit.trim_end_matches(".service").to_owned(),
        "--description".into(),
        format!("Spark OS update {job_id}"),
        "--property=ProtectHome=yes".into(),
        "--property=PrivateTmp=yes".into(),
        "--setenv=DEBIAN_FRONTEND=noninteractive".into(),
        "--".into(),
        SPARK_UPDATER_BIN.into(),
        "os-update".into(),
        "--job-id".into(),
        job_id.to_owned(),
    ];
    if system_packages {
        argv.push("--system-packages".into());
    }
    if firmware {
        argv.push("--firmware".into());
    }
    argv
}

/// Run a fixed program through systemd outside the helper sandbox and capture its result.
pub fn host_command_argv(program: &str, args: &[String]) -> Vec<String> {
    let mut argv: Vec<String> = vec![
        "--quiet".into(),
        "--wait".into(),
        "--pipe".into(),
        "--collect".into(),
        "--property=ProtectHome=yes".into(),
        "--property=PrivateTmp=yes".into(),
        "--setenv=DEBIAN_FRONTEND=noninteractive".into(),
        "--".into(),
        program.to_owned(),
    ];
    argv.extend(args.iter().cloned());
    argv
}

/// Read outcomes only from private regular files owned by the helper; None means no outcome exists yet.
pub(super) fn read_system_update_outcome(
    root: &std::path::Path,
    job_id: &str,
) -> Result<Option<serde_json::Value>, BackendError> {
    use std::io::Read as _;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let path = root.join(format!("{job_id}.json"));
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(BackendError::Failure(format!(
                "could not read the OS update outcome: {error}"
            )));
        }
    };
    let metadata = file
        .metadata()
        .map_err(|error| BackendError::Failure(error.to_string()))?;
    // SAFETY: geteuid has no preconditions and cannot fail.
    let own_uid = unsafe { libc::geteuid() };
    if !metadata.is_file()
        || metadata.uid() != own_uid
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > MAX_SYSTEM_UPDATE_OUTCOME_BYTES
    {
        return Err(BackendError::Failure(
            "UPDATE_STATE_INVALID OS update outcome is not a private file owned by the helper"
                .into(),
        ));
    }
    let mut bytes = Vec::new();
    file.take(MAX_SYSTEM_UPDATE_OUTCOME_BYTES)
        .read_to_end(&mut bytes)
        .map_err(|error| BackendError::Failure(error.to_string()))?;
    serde_json::from_slice(&bytes).map(Some).map_err(|error| {
        BackendError::Failure(format!("OS update outcome is not valid JSON: {error}"))
    })
}

/// Retain the newest log lines within line and byte limits, reporting any truncation.
pub(super) fn diagnostic_log_response(
    request_id: uuid::Uuid,
    source: LogSource,
    stdout: &[u8],
) -> PrivilegedResponse {
    let text = String::from_utf8_lossy(stdout);
    let mut lines: Vec<&str> = text.lines().collect();
    let mut truncated = false;
    if lines.len() > MAX_DIAGNOSTIC_LOG_LINES as usize {
        lines.drain(..lines.len() - MAX_DIAGNOSTIC_LOG_LINES as usize);
        truncated = true;
    }
    let mut retained: Vec<String> = Vec::new();
    let mut bytes = 0usize;
    for line in lines.iter().rev() {
        // `+ 1` for the newline the joined form will carry.
        if bytes + line.len() + 1 > MAX_DIAGNOSTIC_LOG_BYTES {
            truncated = true;
            break;
        }
        bytes += line.len() + 1;
        retained.push((*line).to_owned());
    }
    retained.reverse();
    PrivilegedResponse {
        request_id,
        accepted: true,
        code: "diagnostic_log".into(),
        message: "bounded log tail".into(),
        details: serde_json::json!({
            "source": source.name(),
            "truncated": truncated,
            "lines": retained,
        }),
    }
}

use super::*;

/// Fixed Tailscale client path; the protocol never accepts a program, socket or tailnet argument.
pub const TAILSCALE_BIN: &str = "/usr/bin/tailscale";

/// The vendor package's own unit; SparkPilot enables it rather than shipping a second daemon.
pub const TAILSCALED_UNIT: &str = "tailscaled.service";

pub const CURL_BIN: &str = "/usr/bin/curl";

/// The exact Ubuntu 24.04 keyring and apt source Tailscale's Linux instructions install.
pub const TAILSCALE_KEYRING_PATH: &str = "/usr/share/keyrings/tailscale-archive-keyring.gpg";

pub const TAILSCALE_KEYRING_URL: &str =
    "https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg";

pub const TAILSCALE_APT_SOURCE_PATH: &str = "/etc/apt/sources.list.d/tailscale.list";

pub const TAILSCALE_APT_SOURCE_URL: &str =
    "https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list";

/// Only a sign-in link on this exact origin is ever handed to the app.
const LOGIN_LINK_PREFIX: &str = "https://login.tailscale.com/a/";

/// `tailscale up` returns with the sign-in link after this window; the caller polls status afterwards.
const UP_ARGS: [&str; 5] = [
    "up",
    "--accept-dns=false",
    "--accept-routes=false",
    "--timeout=15s",
    "--json",
];

const STATUS_ARGS: [&str; 2] = ["status", "--json"];

const ENABLE_ARGS: [&str; 3] = ["enable", "--now", TAILSCALED_UNIT];

const DISABLE_ARGS: [&str; 3] = ["disable", "--now", TAILSCALED_UNIT];

const IS_ACTIVE_ARGS: [&str; 2] = ["is-active", TAILSCALED_UNIT];

const LOGOUT_ARGS: [&str; 1] = ["logout"];

/// The only release the pinned vendor apt source matches; other releases report not_installed.
const SUPPORTED_CODENAME: &str = "VERSION_CODENAME=noble";

/// Host paths the overlay operations consult; tests point them at temporary files.
#[derive(Debug, Clone)]
pub struct TailscalePaths {
    pub binary: PathBuf,
    pub apt_source: PathBuf,
    pub os_release: PathBuf,
}

impl Default for TailscalePaths {
    fn default() -> Self {
        Self {
            binary: PathBuf::from(TAILSCALE_BIN),
            apt_source: PathBuf::from(TAILSCALE_APT_SOURCE_PATH),
            os_release: PathBuf::from("/etc/os-release"),
        }
    }
}

/// What the helper learned about the Tailscale client, reported to sparkd as `details`.
#[derive(Debug, Default)]
struct OverlaySetup {
    state: &'static str,
    authorization_url: Option<String>,
    hostname: Option<String>,
    address: Option<String>,
    tailnet: Option<String>,
    installable: Option<bool>,
    detail: Option<String>,
    /// This prepare started a unit that was not already running, so a rollback may stop it again.
    created_service: Option<bool>,
    /// This prepare ran `tailscale up`, so a rollback may sign out again.
    attempted_login: Option<bool>,
}

impl OverlaySetup {
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "provider": "tailscale",
            "state": self.state,
            "authorization_url": self.authorization_url,
            "hostname": self.hostname,
            "address": self.address,
            "tailnet": self.tailnet,
            "installable": self.installable,
            "detail": self.detail,
            "created_service": self.created_service,
            "attempted_login": self.attempted_login,
        })
    }
}

#[derive(Debug, Default, serde::Deserialize)]
struct StatusDocument {
    #[serde(default, rename = "BackendState")]
    backend_state: String,
    #[serde(default, rename = "AuthURL")]
    auth_url: String,
    #[serde(default, rename = "MagicDNSSuffix")]
    magic_dns_suffix: String,
    #[serde(default, rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
    #[serde(default, rename = "Self")]
    self_node: Option<SelfDocument>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct SelfDocument {
    #[serde(default, rename = "DNSName")]
    dns_name: String,
    #[serde(default, rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
}

fn is_tailscale_ipv4(value: &str) -> bool {
    value.parse::<Ipv4Addr>().is_ok_and(|address| {
        let octets = address.octets();
        octets[0] == 100 && (64..=127).contains(&octets[1])
    })
}

fn trusted_login_link(value: &str) -> bool {
    value.strip_prefix(LOGIN_LINK_PREFIX).is_some_and(|token| {
        !token.is_empty()
            && token.len() <= 256
            && token.bytes().all(|byte| byte.is_ascii_alphanumeric())
    })
}

/// Read every JSON document the CLI wrote; `up --json` and `status --json` both emit whole objects.
fn parse_documents(stdout: &[u8]) -> Result<Vec<StatusDocument>, BackendError> {
    serde_json::Deserializer::from_slice(stdout)
        .into_iter::<StatusDocument>()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| {
            BackendError::Failure("Tailscale returned an unreadable status document".into())
        })
}

fn interpret(document: StatusDocument) -> Result<OverlaySetup, BackendError> {
    let self_node = document.self_node.unwrap_or_default();
    let address = document
        .tailscale_ips
        .iter()
        .flatten()
        .chain(self_node.tailscale_ips.iter().flatten())
        .find(|candidate| is_tailscale_ipv4(candidate))
        .cloned();
    let dns_name =
        Some(self_node.dns_name.trim_end_matches('.').to_owned()).filter(|name| !name.is_empty());
    let authorization_url = if document.auth_url.is_empty() {
        None
    } else if trusted_login_link(&document.auth_url) {
        Some(document.auth_url)
    } else {
        return Err(BackendError::Failure(
            "Tailscale returned an untrusted sign-in link; refusing to show it".into(),
        ));
    };
    let state = match document.backend_state.as_str() {
        "Running" if address.is_some() => "ready",
        "Running" | "Starting" | "NoState" => "connecting",
        "NeedsMachineAuth" => "approval_required",
        "NeedsLogin" => "login_required",
        "Stopped" => "stopped",
        _ => "unavailable",
    };
    Ok(OverlaySetup {
        state,
        authorization_url,
        hostname: if state == "ready" {
            dns_name.or_else(|| address.clone())
        } else {
            dns_name
        },
        address,
        tailnet: Some(document.magic_dns_suffix).filter(|suffix| !suffix.is_empty()),
        installable: None,
        detail: None,
        created_service: None,
        attempted_login: None,
    })
}

pub(super) struct OverlayOps<'a> {
    pub(super) commands: appliance_commands::ApplianceCommands<'a>,
    pub(super) paths: &'a TailscalePaths,
}

impl OverlayOps<'_> {
    pub(super) fn execute(
        &self,
        op: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let request_id = op.request_id();
        match op {
            PrivilegedOperation::TailscaleStatus { .. } => Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "tailscale_status".into(),
                message: "Tailscale state read".into(),
                details: self.status()?.json(),
            }),
            PrivilegedOperation::RollBackTailscale {
                logout,
                disable_service,
                ..
            } => {
                if self.commands.plan_only {
                    return Ok(self.rollback_plan(request_id));
                }
                let remaining = self.roll_back(*logout, *disable_service);
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: if remaining.is_empty() {
                        "tailscale_rolled_back"
                    } else {
                        "tailscale_rollback_incomplete"
                    }
                    .into(),
                    message: "Tailscale rollback attempted".into(),
                    details: serde_json::json!({
                        "logged_out": *logout && !remaining.contains(&"signed_in"),
                        "service_disabled": *disable_service
                            && !remaining.contains(&"tailscaled_enabled"),
                        "remaining": remaining,
                    }),
                })
            }
            PrivilegedOperation::PrepareTailscale { .. } => {
                if self.commands.plan_only {
                    return Ok(self.plan(request_id));
                }
                let setup = self.prepare()?;
                let code = match setup.state {
                    "ready" => "tailscale_ready",
                    "login_required" => "tailscale_login_required",
                    "approval_required" => "tailscale_approval_required",
                    _ => "tailscale_prepared",
                };
                Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: code.into(),
                    message: "Tailscale prepared".into(),
                    details: setup.json(),
                })
            }
            _ => Err(BackendError::InvalidInput(
                "operation does not belong to this control boundary".into(),
            )),
        }
    }

    fn plan(&self, request_id: uuid::Uuid) -> PrivilegedResponse {
        let planned = OverlaySetup {
            state: "unavailable",
            ..OverlaySetup::default()
        };
        let mut details = planned.json();
        details["planned"] = serde_json::json!(true);
        details["commands"] = serde_json::json!([
            [SYSTEMCTL_BIN, ENABLE_ARGS.join(" ")],
            [TAILSCALE_BIN, STATUS_ARGS.join(" ")],
            [TAILSCALE_BIN, UP_ARGS.join(" ")],
        ]);
        PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "Tailscale setup plan approved".into(),
            details,
        }
    }

    fn rollback_plan(&self, request_id: uuid::Uuid) -> PrivilegedResponse {
        PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: "Tailscale rollback plan approved".into(),
            details: serde_json::json!({
                "planned": true,
                "commands": [
                    [TAILSCALE_BIN, LOGOUT_ARGS.join(" ")],
                    [SYSTEMCTL_BIN, DISABLE_ARGS.join(" ")],
                ],
            }),
        }
    }

    /// Undo what a prepare started, and name whatever could not be undone.
    fn roll_back(&self, logout: bool, disable_service: bool) -> Vec<&'static str> {
        let mut remaining = Vec::new();
        if logout {
            let args = LOGOUT_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
            let undone = self.paths.binary.is_file()
                && self
                    .commands
                    .run_appliance(TAILSCALE_BIN, args, None)
                    .is_ok_and(|output| output.success());
            if !undone {
                remaining.push("signed_in");
            }
        }
        if disable_service {
            let args = DISABLE_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
            let undone = self
                .commands
                .run_appliance(SYSTEMCTL_BIN, args, None)
                .is_ok_and(|output| output.success());
            if !undone {
                remaining.push("tailscaled_enabled");
            }
        }
        remaining
    }

    /// Whether the vendor unit is already running, so a rollback knows whether this prepare started it.
    fn unit_is_active(&self) -> bool {
        let args = IS_ACTIVE_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
        self.commands
            .run_appliance(SYSTEMCTL_BIN, args, None)
            .is_ok_and(|output| output.success())
    }

    fn installable(&self) -> bool {
        fs::read_to_string(&self.paths.os_release)
            .is_ok_and(|text| text.lines().any(|line| line.trim() == SUPPORTED_CODENAME))
    }

    fn not_installed(&self) -> OverlaySetup {
        OverlaySetup {
            state: "not_installed",
            installable: Some(self.installable()),
            detail: Some("Tailscale is not installed on this Spark".into()),
            ..OverlaySetup::default()
        }
    }

    fn status(&self) -> Result<OverlaySetup, BackendError> {
        if !self.paths.binary.is_file() {
            return Ok(self.not_installed());
        }
        self.installed_status()
    }

    /// Ask the CLI directly; after an install step the binary check would only repeat what apt already proved.
    fn installed_status(&self) -> Result<OverlaySetup, BackendError> {
        let args = STATUS_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
        let output = self.commands.run_appliance(TAILSCALE_BIN, args, None)?;
        if output.stdout.is_empty() {
            // The CLI writes no document when it cannot reach tailscaled's socket.
            return Ok(OverlaySetup {
                state: "stopped",
                detail: Some(output.stderr_text()),
                ..OverlaySetup::default()
            });
        }
        let document = parse_documents(&output.stdout)?.pop().unwrap_or_default();
        interpret(document)
    }

    fn prepare(&self) -> Result<OverlaySetup, BackendError> {
        if !self.paths.binary.is_file() {
            self.install()?;
        }
        // Read the unit before touching it, so a rollback only stops what this prepare started.
        let created_service = !self.unit_is_active();
        let enable = ENABLE_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
        let output = self.commands.run_appliance(SYSTEMCTL_BIN, enable, None)?;
        if !output.success() {
            return Err(BackendError::Failure(format!(
                "tailscaled could not be enabled and started: {}",
                output.stderr_text()
            )));
        }
        let mark = |mut setup: OverlaySetup, attempted_login: bool| {
            setup.created_service = Some(created_service);
            setup.attempted_login = Some(attempted_login);
            setup
        };
        let current = self.installed_status()?;
        if matches!(current.state, "ready" | "approval_required")
            || current.authorization_url.is_some()
        {
            return Ok(mark(current, false));
        }
        let up = UP_ARGS.iter().map(|arg| (*arg).to_owned()).collect();
        let output = self.commands.run_appliance(TAILSCALE_BIN, up, None)?;
        let documents = parse_documents(&output.stdout)?;
        if let Some(document) = documents
            .into_iter()
            .rev()
            .find(|document| !document.auth_url.is_empty())
        {
            let mut setup = interpret(document)?;
            if setup.state != "ready" {
                setup.state = "login_required";
            }
            return Ok(mark(setup, true));
        }
        if output.success() {
            return self.installed_status().map(|setup| mark(setup, true));
        }
        // Without a link the CLI's own reason is the owner's next action (for example custom settings).
        Err(BackendError::Failure(format!(
            "Tailscale could not start sign-in: {}",
            output.stderr_text().trim()
        )))
    }

    /// Install the vendor package exactly as Tailscale's Ubuntu 24.04 instructions do, outside the read-only helper sandbox.
    fn install(&self) -> Result<(), BackendError> {
        if !self.installable() {
            return Err(BackendError::Failure(
                "Tailscale is not installed and this Spark's OS release is not one SparkPilot can install it on"
                    .into(),
            ));
        }
        if !self.paths.apt_source.exists() {
            self.host(
                CURL_BIN,
                &curl_args(TAILSCALE_KEYRING_PATH, TAILSCALE_KEYRING_URL),
            )?;
            self.host(
                CURL_BIN,
                &curl_args(TAILSCALE_APT_SOURCE_PATH, TAILSCALE_APT_SOURCE_URL),
            )?;
            self.host(APT_GET_BIN, &["update"])?;
        }
        self.host(
            APT_GET_BIN,
            &["install", "-y", "--no-install-recommends", "tailscale"],
        )
    }

    fn host(&self, program: &str, args: &[&str]) -> Result<(), BackendError> {
        let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        let output = self.commands.run_appliance(
            SYSTEMD_RUN_BIN,
            host_command_argv(program, &args),
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(format!(
                "Tailscale install step failed ({program}): {}",
                output.stderr_text().trim()
            )));
        }
        Ok(())
    }
}

fn curl_args<'a>(output: &'a str, url: &'a str) -> [&'a str; 10] {
    [
        "--proto",
        "=https",
        "--tlsv1.2",
        "--fail",
        "--silent",
        "--show-error",
        "--location",
        "--output",
        output,
        url,
    ]
}

/// Deterministic answers for the fake backend: setup always needs the owner's sign-in.
pub(super) fn fake_response(op: &PrivilegedOperation) -> PrivilegedResponse {
    let request_id = op.request_id();
    if let PrivilegedOperation::RollBackTailscale {
        logout,
        disable_service,
        ..
    } = op
    {
        return PrivilegedResponse {
            request_id,
            accepted: true,
            code: "tailscale_rolled_back".into(),
            message: "fake Tailscale rollback".into(),
            details: serde_json::json!({
                "logged_out": *logout,
                "service_disabled": *disable_service,
                "remaining": Vec::<String>::new(),
            }),
        };
    }
    let login = matches!(op, PrivilegedOperation::PrepareTailscale { .. });
    let setup = OverlaySetup {
        state: if login {
            "login_required"
        } else {
            "unavailable"
        },
        authorization_url: login.then(|| format!("{LOGIN_LINK_PREFIX}0123456789abcdef")),
        ..OverlaySetup::default()
    };
    PrivilegedResponse {
        request_id,
        accepted: true,
        code: if login {
            "tailscale_login_required"
        } else {
            "tailscale_status"
        }
        .into(),
        message: "fake Tailscale state".into(),
        details: setup.json(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_vendor_login_origin_is_trusted() {
        assert!(trusted_login_link(
            "https://login.tailscale.com/a/0123456789abcdef"
        ));
        assert!(!trusted_login_link("https://login.tailscale.com/a/"));
        assert!(!trusted_login_link(
            "https://login.tailscale.com.evil.example/a/0123"
        ));
        assert!(!trusted_login_link("http://login.tailscale.com/a/0123"));
        assert!(!trusted_login_link(
            "https://login.tailscale.com/a/0123?x=../"
        ));
    }

    #[test]
    fn a_running_node_without_an_address_is_still_connecting() {
        let document = StatusDocument {
            backend_state: "Running".into(),
            ..StatusDocument::default()
        };
        assert_eq!(interpret(document).unwrap().state, "connecting");
    }
}

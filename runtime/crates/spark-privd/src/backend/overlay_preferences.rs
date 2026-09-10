use super::*;

/// Decode only public preferences: the rest of `debug prefs` can contain private keys.
#[derive(serde::Deserialize)]
struct Preferences {
    #[serde(rename = "WantRunning")]
    enabled: bool,
    #[serde(rename = "CorpDNS")]
    accept_dns: bool,
}

impl Preferences {
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "provider": "tailscale", "enabled": self.enabled, "accept_dns": self.accept_dns,
        })
    }
}

pub(super) struct OverlayPreferencesOps<'a> {
    pub(super) commands: appliance_commands::ApplianceCommands<'a>,
    pub(super) paths: &'a overlay_ops::TailscalePaths,
}

impl OverlayPreferencesOps<'_> {
    pub(super) fn execute(
        &self,
        op: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let change = match op {
            PrivilegedOperation::TailscalePreferences { .. } => None,
            PrivilegedOperation::ConfigureTailscale {
                enabled,
                accept_dns,
                ..
            } if enabled.is_some() != accept_dns.is_some() => Some((*enabled, *accept_dns)),
            _ => {
                return Err(BackendError::InvalidInput(
                    "change exactly one Tailscale preference".into(),
                ));
            }
        };
        if self.commands.plan_only {
            return Ok(PrivilegedResponse::rejected(
                op.request_id(),
                "tailscale_unavailable",
                "live preferences are unavailable in planning mode",
            ));
        }
        if !self.paths.binary.is_file() {
            return Err(BackendError::Failure(
                "Tailscale is not installed on this Spark".into(),
            ));
        }
        let current = self.preferences()?;
        let preferences = if let Some((enabled, accept_dns)) = change {
            if enabled.is_some_and(|value| value != current.enabled) {
                if enabled == Some(true) {
                    self.require_existing_login()?;
                }
                self.run(&[if enabled == Some(true) { "up" } else { "down" }])?;
            }
            if accept_dns.is_some_and(|value| value != current.accept_dns) {
                self.run(&[
                    "set",
                    if accept_dns == Some(true) {
                        "--accept-dns=true"
                    } else {
                        "--accept-dns=false"
                    },
                ])?;
            }
            let observed = self.preferences()?;
            if enabled.is_some_and(|value| observed.enabled != value)
                || accept_dns.is_some_and(|value| observed.accept_dns != value)
            {
                return Err(BackendError::Failure(
                    "Tailscale did not apply the requested preference; refresh its status".into(),
                ));
            }
            observed
        } else {
            current
        };
        Ok(PrivilegedResponse {
            request_id: op.request_id(),
            accepted: true,
            code: if change.is_some() {
                "tailscale_configured"
            } else {
                "tailscale_preferences"
            }
            .into(),
            message: "Tailscale preferences verified".into(),
            details: preferences.json(),
        })
    }

    fn preferences(&self) -> Result<Preferences, BackendError> {
        let output = self.run(&["debug", "prefs"])?;
        serde_json::from_slice(&output.stdout)
            .map_err(|_| BackendError::Failure("Tailscale preferences could not be read".into()))
    }

    fn require_existing_login(&self) -> Result<(), BackendError> {
        #[derive(serde::Deserialize)]
        struct Status {
            #[serde(rename = "BackendState")]
            state: String,
        }
        let output = self.run(&["status", "--json"])?;
        let status: Status = serde_json::from_slice(&output.stdout).map_err(|_| {
            BackendError::Failure("Tailscale sign-in status could not be read".into())
        })?;
        if !matches!(status.state.as_str(), "Stopped" | "Running" | "Starting") {
            return Err(BackendError::Failure(
                "Tailscale needs sign-in or approval; use Set up step by step".into(),
            ));
        }
        Ok(())
    }

    fn run(&self, arguments: &[&str]) -> Result<crate::update::CommandOutput, BackendError> {
        // An external deadline leaves `up` bare, preserving every previously saved preference.
        let args = ["--kill-after=2s", "20s", overlay_ops::TAILSCALE_BIN]
            .into_iter()
            .chain(arguments.iter().copied())
            .map(String::from)
            .collect();
        let output = self
            .commands
            .run_appliance("/usr/bin/timeout", args, None)
            .map_err(|_| {
                BackendError::Failure("Tailscale did not finish the requested action".into())
            })?;
        if !output.success() {
            return Err(BackendError::Failure(
                "Tailscale could not complete the action; check its status and try again".into(),
            ));
        }
        Ok(output)
    }
}

impl DockerBackend {
    pub(super) fn execute_overlay(
        &self,
        op: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let _guard =
            if matches!(op, PrivilegedOperation::TailscaleStatus { .. }) {
                None
            } else {
                Some(self.tailscale_mutation.try_lock().map_err(|_| {
                    BackendError::Failure("another Tailscale change is running".into())
                })?)
            };
        if matches!(
            op,
            PrivilegedOperation::TailscalePreferences { .. }
                | PrivilegedOperation::ConfigureTailscale { .. }
        ) {
            OverlayPreferencesOps {
                commands: self.appliance_commands(),
                paths: &self.tailscale_paths,
            }
            .execute(op)
        } else {
            overlay_ops::OverlayOps {
                commands: self.appliance_commands(),
                paths: &self.tailscale_paths,
            }
            .execute(op)
        }
    }
}

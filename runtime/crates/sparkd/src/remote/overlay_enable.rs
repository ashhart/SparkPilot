use super::*;

use std::time::{Duration, Instant};

use crate::remote_overlay_setup::{OverlayRollback, OverlaySetup, OverlaySetupState};

pub const STAGE_PREPARING: &str = "preparing_overlay";

pub const STAGE_AWAITING_SIGN_IN: &str = "awaiting_owner_login";

pub const STAGE_AWAITING_APPROVAL: &str = "awaiting_tailnet_approval";

pub const STAGE_VERIFYING: &str = "verifying_route";

pub const STAGE_PUBLISHING: &str = "publishing_route";

/// The owner has this long to finish the browser sign-in before the enable fails with a next action.
pub const OWNER_SIGN_IN_WINDOW: Duration = Duration::from_secs(10 * 60);

pub const OWNER_SIGN_IN_POLL: Duration = Duration::from_secs(3);

/// After sign-in the overlay address can take a few seconds to answer; verify this many times before failing.
const VERIFICATION_ATTEMPTS: usize = 10;

/// Observe a one-tap enable so the durable operation can publish its stage while the owner signs in.
pub trait OverlayEnableProgress {
    /// Return false to abandon the enable, for example when the operation was cancelled.
    fn stage(&self, stage: &str, setup: Option<&OverlaySetup>) -> bool;
}

/// Direct calls without an operation behind them observe nothing.
#[derive(Debug, Default)]
pub struct NoOverlayProgress;

impl OverlayEnableProgress for NoOverlayProgress {
    fn stage(&self, _stage: &str, _setup: Option<&OverlaySetup>) -> bool {
        true
    }
}

impl RemoteAccessService {
    /// Use an enrolled route straight away; otherwise set Tailscale up, wait for the owner, then publish.
    pub(super) fn enable_overlay(
        &self,
        progress: &dyn OverlayEnableProgress,
    ) -> Result<RemoteStatusRow, RemoteError> {
        if let Some(route) = self
            .private_overlay
            .route()
            .map_err(RemoteError::RunnerFailed)?
        {
            // An overlay this Spark already had: nothing here created it, so nothing here undoes it.
            return self.publish_overlay_route(route, progress);
        }
        if !progress.stage(STAGE_PREPARING, None) {
            return Err(RemoteError::Cancelled);
        }
        let setup = self
            .provisioner
            .prepare()
            .map_err(RemoteError::OverlaySetupFailed)?;
        // From here on the Spark may be joined to a tailnet, so no failure leaves without undoing it.
        let undo = OverlayRollback::after(&setup);
        self.finish_provisioning(progress, setup)
            .and_then(|route| self.publish_overlay_route(route, progress))
            .map_err(|error| self.undo(undo, error))
    }

    /// Carry a prepared overlay to a verified route; every exit from here is rolled back by the caller.
    fn finish_provisioning(
        &self,
        progress: &dyn OverlayEnableProgress,
        mut setup: OverlaySetup,
    ) -> Result<PrivateOverlayRoute, RemoteError> {
        let deadline = Instant::now() + self.sign_in_window;
        let mut announced = false;
        loop {
            match setup.state {
                OverlaySetupState::Ready => break,
                OverlaySetupState::LoginRequired | OverlaySetupState::ApprovalRequired => {
                    if !announced {
                        self.emit_event(
                            "remote.overlay.login_required",
                            "notice",
                            json!({
                                "provider": setup.provider,
                                "state": setup.state.api_name(),
                                "has_link": setup.authorization_url.is_some(),
                            }),
                        );
                        announced = true;
                    }
                    let stage = if setup.state == OverlaySetupState::LoginRequired {
                        STAGE_AWAITING_SIGN_IN
                    } else {
                        STAGE_AWAITING_APPROVAL
                    };
                    if !progress.stage(stage, Some(&setup)) {
                        return Err(RemoteError::Cancelled);
                    }
                    if Instant::now() >= deadline {
                        return Err(RemoteError::OverlaySignInTimeout);
                    }
                }
                OverlaySetupState::Connecting | OverlaySetupState::Stopped => {
                    if !progress.stage(STAGE_PREPARING, Some(&setup)) {
                        return Err(RemoteError::Cancelled);
                    }
                    if Instant::now() >= deadline {
                        return Err(RemoteError::OverlaySetupFailed(format!(
                            "Tailscale stayed {} instead of connecting",
                            setup.state.api_name()
                        )));
                    }
                }
                OverlaySetupState::NotInstalled | OverlaySetupState::Unavailable => {
                    return Err(RemoteError::OverlaySetupFailed(
                        setup.detail.clone().unwrap_or_else(|| {
                            format!("Tailscale reported {}", setup.state.api_name())
                        }),
                    ));
                }
            }
            std::thread::sleep(self.sign_in_poll);
            setup = self
                .provisioner
                .status()
                .map_err(RemoteError::OverlaySetupFailed)?;
        }
        if !progress.stage(STAGE_VERIFYING, Some(&setup)) {
            return Err(RemoteError::Cancelled);
        }
        for attempt in 0..VERIFICATION_ATTEMPTS {
            if let Some(route) = self
                .private_overlay
                .route()
                .map_err(RemoteError::RunnerFailed)?
            {
                return Ok(route);
            }
            if attempt + 1 < VERIFICATION_ATTEMPTS {
                std::thread::sleep(self.sign_in_poll);
            }
        }
        Err(RemoteError::OverlayRouteUnverified)
    }

    /// Undo what this enable started; if it cannot, say exactly what is left in place.
    fn undo(&self, undo: OverlayRollback, error: RemoteError) -> RemoteError {
        if undo.is_empty() {
            return error;
        }
        let outcome = self.provisioner.roll_back(undo);
        let remaining = match &outcome {
            Ok(report) if report.remaining.is_empty() => {
                self.emit_event(
                    "remote.overlay.rolled_back",
                    "notice",
                    json!({
                        "reason": error.to_string(),
                        "logged_out": report.logged_out,
                        "service_disabled": report.service_disabled,
                    }),
                );
                return error;
            }
            Ok(report) => report.remaining_summary(),
            Err(reason) => {
                format!("the Spark could not be returned to its previous state: {reason}")
            }
        };
        self.emit_event(
            "remote.overlay.rollback_failed",
            "error",
            json!({
                "reason": error.to_string(),
                "remaining": remaining,
            }),
        );
        RemoteError::OverlayRollbackIncomplete(format!("{error}; {remaining}"))
    }

    /// Persist the verified route; an identical healthy row is left untouched so replays stay idempotent.
    fn publish_overlay_route(
        &self,
        route: PrivateOverlayRoute,
        progress: &dyn OverlayEnableProgress,
    ) -> Result<RemoteStatusRow, RemoteError> {
        if !progress.stage(STAGE_PUBLISHING, None) {
            return Err(RemoteError::Cancelled);
        }
        let hostname = route.hostname.clone();
        let current = self.status()?;
        if current.enabled
            && current.mode == "private_overlay"
            && current.hostname.as_deref() == Some(hostname.as_str())
            && current.health == "healthy"
        {
            return Ok(current);
        }
        {
            let conn = self.database.lock();
            write_row(
                &conn,
                &RemoteStatusRow {
                    enabled: true,
                    mode: "private_overlay".into(),
                    health: "healthy".into(),
                    hostname: Some(hostname.clone()),
                    available_modes: Vec::new(),
                    private_overlay_provider: None,
                    private_overlay_address: None,
                },
            )?;
        }
        self.emit_enabled("private_overlay", Some(hostname));
        self.status()
    }
}

/// The operation error code an enable failure maps to (`docs/ERROR_CODES.md`).
pub fn enable_failure_code(error: &RemoteError) -> &'static str {
    match error {
        RemoteError::OverlaySetupFailed(_) => "PRIVATE_OVERLAY_SETUP_FAILED",
        RemoteError::OverlaySignInTimeout => "PRIVATE_OVERLAY_LOGIN_TIMEOUT",
        RemoteError::OverlayRouteUnverified => "PRIVATE_OVERLAY_ROUTE_UNVERIFIED",
        RemoteError::Cancelled => "OPERATION_CANCELLED",
        RemoteError::OverlayRollbackIncomplete(_) => "PRIVATE_OVERLAY_ROLLBACK_INCOMPLETE",
        _ => "REMOTE_ENABLE_FAILED",
    }
}

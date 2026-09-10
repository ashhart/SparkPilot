//! Manage private remote access while retaining pinned identity, device signatures and role checks.
use crate::events::EventBus;
use parking_lot::Mutex;
use rusqlite::Connection;
use serde::Serialize;
use serde_json::{Value, json};
use std::sync::Arc;

pub use crate::remote_overlay::{
    PrivateOverlayProbe, PrivateOverlayRoute, TailscaleOverlayProbe, UnavailablePrivateOverlay,
};

use crate::remote_overlay_setup::{
    OverlayPreferenceChange, OverlayPreferences, OverlaySetup, PrivateOverlayProvisioner,
    UnavailableOverlayProvisioner,
};

#[derive(Debug, thiserror::Error)]
pub enum RemoteError {
    #[error("remote configuration is invalid: {0}")]
    ConfigInvalid(String),
    #[error("private route probe failed: {0}")]
    RunnerFailed(String),
    #[error("storage error: {0}")]
    Storage(String),
    #[error("private overlay setup failed: {0}")]
    OverlaySetupFailed(String),
    #[error("the owner did not finish the Tailscale sign-in in time")]
    OverlaySignInTimeout,
    #[error("the overlay route could not be verified after sign-in")]
    OverlayRouteUnverified,
    #[error("the remote change was cancelled")]
    Cancelled,
    #[error("the private overlay could not be undone after a failed enable: {0}")]
    OverlayRollbackIncomplete(String),
}

impl From<rusqlite::Error> for RemoteError {
    fn from(error: rusqlite::Error) -> Self {
        RemoteError::Storage(error.to_string())
    }
}

impl From<std::io::Error> for RemoteError {
    fn from(error: std::io::Error) -> Self {
        RemoteError::Storage(error.to_string())
    }
}

// Manage the persisted remote-access state and its transport evidence.

/// The `remote_access` row as the API reports it (`RemoteStatus` schema).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RemoteStatusRow {
    pub enabled: bool,
    pub mode: String,
    pub health: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hostname: Option<String>,
    pub available_modes: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub private_overlay_provider: Option<String>,
    /// The live 100.64/10 address beside the published name; never persisted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub private_overlay_address: Option<String>,
}

pub struct RemoteAccessService {
    database: Arc<Mutex<Connection>>,
    events: EventBus,
    node_id: String,
    private_overlay: Arc<dyn PrivateOverlayProbe>,
    provisioner: Arc<dyn PrivateOverlayProvisioner>,
    sign_in_window: std::time::Duration,
    sign_in_poll: std::time::Duration,
    mutation: Mutex<()>,
}

impl RemoteAccessService {
    pub fn new(database: Arc<Mutex<Connection>>, events: EventBus, node_id: String) -> Self {
        Self {
            database,
            events,
            node_id,
            private_overlay: Arc::new(UnavailablePrivateOverlay),
            provisioner: Arc::new(UnavailableOverlayProvisioner),
            sign_in_window: OWNER_SIGN_IN_WINDOW,
            sign_in_poll: OWNER_SIGN_IN_POLL,
            mutation: Mutex::new(()),
        }
    }

    pub fn with_private_overlay_probe(mut self, probe: Arc<dyn PrivateOverlayProbe>) -> Self {
        self.private_overlay = probe;
        self
    }

    /// Attach the helper-backed provisioner that installs, starts and signs Tailscale in.
    pub fn with_private_overlay_provisioner(
        mut self,
        provisioner: Arc<dyn PrivateOverlayProvisioner>,
    ) -> Self {
        self.provisioner = provisioner;
        self
    }

    /// Shorten the owner's sign-in window and poll cadence in deterministic tests.
    pub fn with_overlay_sign_in_window(
        mut self,
        window: std::time::Duration,
        poll: std::time::Duration,
    ) -> Self {
        self.sign_in_window = window;
        self.sign_in_poll = poll;
        self
    }

    /// The helper's live Tailscale state, including the sign-in link while an enable waits for the owner.
    pub fn overlay_setup(&self) -> Result<OverlaySetup, RemoteError> {
        self.provisioner
            .status()
            .map_err(RemoteError::OverlaySetupFailed)
    }

    pub fn overlay_preferences(&self) -> Result<OverlayPreferences, RemoteError> {
        self.provisioner
            .preferences()
            .map_err(RemoteError::OverlaySetupFailed)
    }

    pub fn configure_overlay(
        &self,
        request_id: uuid::Uuid,
        change: OverlayPreferenceChange,
    ) -> Result<OverlayPreferences, RemoteError> {
        let _guard = self.mutation.try_lock().ok_or_else(|| {
            RemoteError::ConfigInvalid("another remote access change is running".into())
        })?;
        if !change.is_valid() {
            return Err(RemoteError::ConfigInvalid(
                "change exactly one preference".into(),
            ));
        }
        let preferences = self
            .provisioner
            .configure(request_id, change)
            .map_err(RemoteError::OverlaySetupFailed)?;
        self.emit_event(
            "remote.preferences.changed",
            "notice",
            json!({"enabled":preferences.enabled,"accept_dns":preferences.accept_dns}),
        );
        // Route health is independent of preference success and will also be reconciled periodically.
        let _ = self.refresh_health();
        Ok(preferences)
    }

    /// The node id this service publishes; the route probe compares it.
    pub fn node_id(&self) -> &str {
        &self.node_id
    }

    pub fn status(&self) -> Result<RemoteStatusRow, RemoteError> {
        let conn = self.database.lock();
        let mut row = read_row(&conn)?;
        drop(conn);
        let overlay = self.private_overlay.route().ok().flatten();
        row.available_modes = overlay
            .as_ref()
            .map(|_| vec!["private_overlay".to_owned()])
            .unwrap_or_default();
        row.private_overlay_address = overlay.as_ref().and_then(|route| route.address.clone());
        row.private_overlay_provider = overlay.map(|route| route.provider);
        Ok(row)
    }

    /// Read persisted mode without transport probes so aggregate reconnect status remains fast.
    pub fn configured_mode(&self) -> Result<String, RemoteError> {
        let conn = self.database.lock();
        read_row(&conn).map(|row| row.mode)
    }

    pub fn private_overlay_route(&self) -> Result<Option<PrivateOverlayRoute>, RemoteError> {
        self.private_overlay
            .route()
            .map_err(RemoteError::RunnerFailed)
    }

    /// Publish the private route after setup and verification.
    pub fn enable(&self, mode: &str) -> Result<RemoteStatusRow, RemoteError> {
        self.enable_with_progress(mode, &NoOverlayProgress)
    }

    pub fn enable_with_progress(
        &self,
        mode: &str,
        progress: &dyn OverlayEnableProgress,
    ) -> Result<RemoteStatusRow, RemoteError> {
        let _guard = self.mutation.try_lock().ok_or_else(|| {
            RemoteError::ConfigInvalid("another remote access change is running".into())
        })?;
        match mode {
            "private_overlay" => self.enable_overlay(progress),
            other => Err(RemoteError::ConfigInvalid(format!(
                "unsupported remote mode: {other}"
            ))),
        }
    }

    /// Stop advertising the private route without changing the owner's Tailscale installation.
    pub fn disable(&self) -> Result<RemoteStatusRow, RemoteError> {
        let _guard = self.mutation.try_lock().ok_or_else(|| {
            RemoteError::ConfigInvalid("another remote access change is running".into())
        })?;
        let was = self.status()?;
        {
            let conn = self.database.lock();
            write_row(
                &conn,
                &RemoteStatusRow {
                    enabled: false,
                    mode: "disabled".into(),
                    health: "disabled".into(),
                    hostname: None,
                    available_modes: Vec::new(),
                    private_overlay_provider: None,
                    private_overlay_address: None,
                },
            )?;
        }
        if was.enabled {
            self.emit_event(
                "remote.tunnel.disabled",
                "notice",
                json!({ "was_mode": was.mode }),
            );
        }
        self.status()
    }

    /// Reconcile the private route with the enrolled Tailscale client.
    pub fn refresh_health(&self) -> Result<RemoteStatusRow, RemoteError> {
        let current = self.status()?;
        if !current.enabled {
            return Ok(current);
        }
        // Adopt a live reassigned overlay address so reauthentication or tailnet changes do not leave stale degraded routes.
        let mut next_hostname = current.hostname.clone();
        let healthy = {
            match self.private_overlay.route() {
                Ok(Some(route)) => {
                    next_hostname = Some(route.hostname);
                    true
                }
                Ok(None) => false,
                Err(error) => {
                    // Treat interface/probe errors as inconclusive and preserve current health rather than declaring route loss.
                    tracing::warn!(
                        %error,
                        "overlay health probe inconclusive; retaining current health"
                    );
                    let healthy = matches!(current.health.as_str(), "healthy" | "starting");
                    healthy
                }
            }
        };
        let next = match (current.health.as_str(), healthy) {
            ("starting", true) => "healthy",
            ("healthy", false) => {
                self.emit_event(
                    "remote.tunnel.unhealthy",
                    "warning",
                    json!({ "mode": current.mode, "hostname": current.hostname }),
                );
                "degraded"
            }
            ("degraded", true) => "healthy",
            (health, _) => health,
        };
        let hostname_changed = next_hostname != current.hostname;
        if next == current.health && !hostname_changed {
            return Ok(current);
        }
        let mut row = current.clone();
        row.health = next.to_owned();
        row.hostname = next_hostname;
        write_row(&self.database.lock(), &row)?;
        // Say so when the published hostname moves: it is the address the owner's traffic takes from now on.
        if hostname_changed {
            let was = current.hostname;
            let payload =
                json!({ "mode": row.mode, "was_hostname": was, "hostname": row.hostname });
            self.emit_event("remote.route.hostname_changed", "notice", payload);
        }
        Ok(row)
    }

    fn emit_enabled(&self, mode: &str, hostname: Option<String>) {
        self.emit_event(
            "remote.tunnel.enabled",
            "notice",
            json!({ "mode": mode, "hostname": hostname }),
        );
    }

    fn emit_event(&self, event_type: &str, severity: &str, payload: Value) {
        let conn = self.database.lock();
        self.events.emit(
            Some(&conn),
            &self.node_id,
            None,
            event_type,
            severity,
            payload,
        );
    }
}

fn read_row(conn: &Connection) -> Result<RemoteStatusRow, RemoteError> {
    conn.query_row(
        "SELECT enabled, mode, health, hostname
         FROM remote_access WHERE singleton = 1",
        [],
        |row| {
            Ok(RemoteStatusRow {
                enabled: row.get::<_, i64>(0)? == 1,
                mode: row.get(1)?,
                health: row.get(2)?,
                hostname: row.get(3)?,
                available_modes: Vec::new(),
                private_overlay_provider: None,
                private_overlay_address: None,
            })
        },
    )
    .or_else(|e| match e {
        rusqlite::Error::QueryReturnedNoRows => Ok(RemoteStatusRow {
            enabled: false,
            mode: "disabled".into(),
            health: "disabled".into(),
            hostname: None,
            available_modes: Vec::new(),
            private_overlay_provider: None,
            private_overlay_address: None,
        }),
        other => Err(other.into()),
    })
}

fn write_row(conn: &Connection, row: &RemoteStatusRow) -> Result<(), RemoteError> {
    conn.execute(
        "INSERT INTO remote_access
            (singleton, enabled, mode, hostname, health, enabled_at, updated_at)
         VALUES (1, ?1, ?2, ?3, ?4, ?5, ?5)
         ON CONFLICT(singleton) DO UPDATE SET
            enabled = excluded.enabled,
            mode = excluded.mode,
            hostname = excluded.hostname,
            health = excluded.health,
            updated_at = excluded.updated_at",
        rusqlite::params![
            row.enabled as i64,
            row.mode,
            row.hostname,
            row.health,
            crate::store::now_iso8601(),
        ],
    )?;
    Ok(())
}

mod overlay_enable;
pub use overlay_enable::{
    NoOverlayProgress, OWNER_SIGN_IN_POLL, OWNER_SIGN_IN_WINDOW, OverlayEnableProgress,
    STAGE_AWAITING_APPROVAL, STAGE_AWAITING_SIGN_IN, STAGE_PREPARING, STAGE_PUBLISHING,
    STAGE_VERIFYING, enable_failure_code,
};

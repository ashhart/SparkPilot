//! Persist exact container ownership before start so recovery cannot adopt an unrecorded container.
use super::*;

use serde::{Deserialize, Serialize};

use serde_json::{Value, json};

use sha2::{Digest, Sha256};

static MUTATION: std::sync::Mutex<()> = std::sync::Mutex::new(());

const JOURNAL: &str = "ownership.json";

const RECOVERY: &str = "Open WebUI ownership cannot be verified; preserve the existing containers and data, inspect them locally, then reinstall into an empty managed service name";

fn ownership_error() -> BackendError {
    BackendError::Failure(RECOVERY.into())
}

impl DockerBackend {
    pub(super) fn open_webui_port(&self) -> u16 {
        self.webui_load()
            .ok()
            .flatten()
            .map_or(OPEN_WEBUI_LOOPBACK_PORT, |j| j.port)
    }

    fn webui_write(&self, name: &str, bytes: &[u8]) -> Result<(), BackendError> {
        self.journal().webui_write(name, bytes)
    }

    fn webui_save(&self, journal: &Journal) -> Result<(), BackendError> {
        self.journal().webui_save(journal)
    }

    fn webui_load(&self) -> Result<Option<Journal>, BackendError> {
        self.journal().webui_load()
    }

    fn webui_command(&self, args: &[&str]) -> Result<Vec<u8>, BackendError> {
        self.inspection().webui_command(args)
    }

    fn webui_inspect(&self, kind: &str, id: &str) -> Result<Option<Value>, BackendError> {
        self.inspection().webui_inspect(kind, id)
    }

    fn webui_verify_container(&self, container: &Container) -> Result<Option<Value>, BackendError> {
        self.inspection().webui_verify_container(container)
    }

    fn webui_verify_volume(&self, volume: &Volume) -> Result<(), BackendError> {
        self.inspection().webui_verify_volume(volume)
    }

    fn webui_verify(&self, journal: Option<&Journal>) -> Result<(), BackendError> {
        self.inspection().webui_verify(journal)
    }

    fn webui_create_volume(&self, journal: &mut Journal) -> Result<(), BackendError> {
        self.volume().webui_create_volume(journal)
    }

    fn webui_remove_exact(&self, container: &Container) -> Result<(), BackendError> {
        self.inspection().webui_remove_exact(container)
    }

    fn webui_wait(&self, container: &Container) -> Result<bool, BackendError> {
        #[cfg(test)]
        if let Some(probe) = &self.open_webui_probe {
            return Ok(probe());
        }
        self.inspection()
            .wait_until_ready(container, || self.open_webui_healthy())
    }

    fn webui_rollback(&self, journal: &mut Journal) -> Result<bool, BackendError> {
        self.webui_verify(Some(journal))?;
        let previous = journal.previous.clone().ok_or_else(ownership_error)?;
        if let Some(current) = &journal.current {
            self.webui_remove_exact(current)?;
        }
        journal.current = None;
        self.webui_save(journal)?;
        let value = self
            .webui_verify_container(&previous)?
            .ok_or_else(ownership_error)?;
        if value["Name"]
            .as_str()
            .map(|name| name.trim_start_matches('/'))
            != Some(OPEN_WEBUI_CONTAINER)
        {
            self.webui_command(&["rename", &previous.id, OPEN_WEBUI_CONTAINER])?;
        }
        self.webui_command(&["start", &previous.id])?;
        journal.current = Some(previous);
        journal.previous = None;
        journal.phase = Phase::Ready;
        self.webui_save(journal)?;
        self.webui_wait(journal.current.as_ref().expect("restored"))
    }

    pub(super) fn execute_open_webui(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let request_id = operation.request_id();
        let reply = |accepted, code: &str, details| PrivilegedResponse {
            request_id,
            accepted,
            code: code.into(),
            message: "Open WebUI service operation".into(),
            details,
        };
        if let PrivilegedOperation::InstallOpenWebUi {
            image_digest,
            admin_email,
            admin_name,
            admin_password,
            gateway_api_key,
            port,
            adopt_existing,
            ..
        } = operation
        {
            if !crate::protocol::valid_open_webui_port(*port) {
                return Err(BackendError::InvalidInput(
                    "Open WebUI port is reserved or outside 1024–65535".into(),
                ));
            }
            self.plan_open_webui_container(image_digest)?;
            if !adopt_existing
                && (!valid_open_webui_admin(
                    admin_email,
                    admin_name,
                    admin_password.expose_secret(),
                ) || !valid_api_key(gateway_api_key.expose_secret()))
            {
                return Err(BackendError::InvalidInput(
                    "Open WebUI credentials fail policy".into(),
                ));
            }
        }
        if let PrivilegedOperation::UpdateOpenWebUi { image_digest, .. } = operation {
            self.plan_open_webui_container(image_digest)?;
        }
        if self.plan_only {
            let details = match operation {
                PrivilegedOperation::InstallOpenWebUi {
                    port,
                    adopt_existing: true,
                    ..
                } => {
                    json!({"service_id":"open-webui","port":port,"adopted":true,"mutates_existing_installation":false})
                }
                PrivilegedOperation::InstallOpenWebUi {
                    image_digest, port, ..
                } => {
                    let mut plan = self.plan_open_webui_container(image_digest)?;
                    for arg in &mut plan.argv {
                        if arg.starts_with("--env=PORT=") {
                            *arg = format!("--env=PORT={port}");
                        }
                    }
                    json!({"argv":plan.argv,"summary":plan.summary,"bootstrap_credentials_in_argv":false})
                }
                PrivilegedOperation::UpdateOpenWebUi { image_digest, .. } => {
                    let plan = self.plan_open_webui_container(image_digest)?;
                    json!({"argv":plan.argv,"summary":plan.summary,"bootstrap_credentials_in_argv":false})
                }
                _ => json!({"service_id":"open-webui"}),
            };
            return Ok(reply(true, "planned", details));
        }
        let _guard = match MUTATION.try_lock() {
            Ok(guard) => guard,
            Err(_) => {
                return Ok(reply(
                    false,
                    "OPEN_WEBUI_OPERATION_IN_PROGRESS",
                    json!({"recovery":{"action":"wait_for_current_operation"}}),
                ));
            }
        };
        if let PrivilegedOperation::InstallOpenWebUi {
            port,
            adopt_existing: true,
            ..
        } = operation
        {
            return self.webui_adopt(request_id, *port);
        }
        if let Ok(Some(mut journal)) = self.webui_load()
            && journal.adopted
        {
            return self.webui_adopted_operation(operation, &mut journal);
        }
        let evidence = self.webui_load().and_then(|journal| {
            self.webui_verify(journal.as_ref())?;
            Ok(journal)
        });
        let mut journal = match evidence {
            Ok(journal) => journal,
            Err(_) => {
                return Ok(reply(
                    matches!(operation, PrivilegedOperation::OpenWebUiStatus { .. }),
                    "OPEN_WEBUI_OWNERSHIP_UNVERIFIED",
                    json!({"installed":true,"running":false,"healthy":false,"ownership_verified":false,"repair_available":false,"recovery":{"code":"OPEN_WEBUI_OWNERSHIP_UNVERIFIED","action":"inspect_locally_preserve_data","message":RECOVERY}}),
                ));
            }
        };
        if matches!(operation, PrivilegedOperation::OpenWebUiStatus { .. }) {
            return self.webui_managed_status(request_id, journal.as_ref());
        }
        match operation {
            PrivilegedOperation::InstallOpenWebUi {
                image_digest,
                admin_email,
                admin_name,
                admin_password,
                gateway_api_key,
                port,
                ..
            } => {
                if journal
                    .as_ref()
                    .is_some_and(|journal| journal.phase != Phase::Removed)
                {
                    return Ok(reply(false, "OPEN_WEBUI_ALREADY_INSTALLED", Value::Null));
                }
                let mut state = journal.take().unwrap_or(Journal {
                    version: 1,
                    port: *port,
                    adopted: false,
                    generation: uuid::Uuid::new_v4(),
                    phase: Phase::Installing,
                    pending_create: false,
                    volume: None,
                    current: None,
                    previous: None,
                    last_repair_epoch: 0,
                    erase_data: false,
                });
                state.port = *port;
                state.adopted = false;
                let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, *port))
                    .map_err(|_| BackendError::Failure("Open WebUI port is already in use; choose another port or connect the existing installation".into()))?;
                drop(listener);
                state.phase = Phase::Installing;
                if state.volume.is_none() {
                    state.generation = uuid::Uuid::new_v4();
                }
                self.webui_save(&state)?;
                self.webui_command(&["pull", image_digest])?;
                if state.volume.is_none() {
                    self.webui_create_volume(&mut state)?;
                }
                self.webui_write(
                    "gateway.env",
                    format!("OPENAI_API_KEY={}\n", gateway_api_key.expose_secret()).as_bytes(),
                )?;
                self.webui_write("bootstrap.env",format!("OPENAI_API_KEY={}\nWEBUI_ADMIN_EMAIL={admin_email}\nWEBUI_ADMIN_NAME={admin_name}\nWEBUI_ADMIN_PASSWORD={}\n",gateway_api_key.expose_secret(),admin_password.expose_secret()).as_bytes())?;
                let _credentials = CredentialGuard(self.open_webui_root.join("bootstrap.env"));
                self.webui_create(&mut state, image_digest, true)?;
                let bootstrap = state.current.as_ref().expect("created");
                let healthy = self.webui_wait(bootstrap)?;
                self.webui_remove_exact(bootstrap)?;
                state.current = None;
                self.webui_save(&state)?;
                if !healthy {
                    return Ok(reply(false, "OPEN_WEBUI_BOOTSTRAP_FAILED", Value::Null));
                }
                self.webui_create(&mut state, image_digest, false)?;
                if !self.webui_wait(state.current.as_ref().expect("created"))? {
                    return Ok(reply(false, "OPEN_WEBUI_START_FAILED", Value::Null));
                }
                state.phase = Phase::Ready;
                self.webui_save(&state)?;
                Ok(reply(
                    true,
                    "open_webui_ready",
                    json!({"state":"healthy","ownership_verified":true}),
                ))
            }
            PrivilegedOperation::UpdateOpenWebUi { image_digest, .. } => {
                let Some(mut state) = journal else {
                    return Ok(reply(false, "OPEN_WEBUI_NOT_INSTALLED", Value::Null));
                };
                if state.phase == Phase::Updating {
                    let restored = self.webui_rollback(&mut state)?;
                    return Ok(reply(
                        false,
                        if restored {
                            "OPEN_WEBUI_UPDATE_ROLLED_BACK"
                        } else {
                            "OPEN_WEBUI_ROLLBACK_FAILED"
                        },
                        Value::Null,
                    ));
                }
                if state.phase != Phase::Ready {
                    return Ok(reply(false, "OPEN_WEBUI_RECOVERY_REQUIRED", Value::Null));
                }
                let current = state.current.clone().ok_or_else(ownership_error)?;
                let value = self
                    .webui_verify_container(&current)?
                    .ok_or_else(ownership_error)?;
                if value["State"]["Running"] != true {
                    return Ok(reply(
                        false,
                        "OPEN_WEBUI_INTENTIONALLY_STOPPED",
                        Value::Null,
                    ));
                }
                if current.image == *image_digest {
                    return Ok(reply(true, "open_webui_current", Value::Null));
                }
                self.webui_command(&["pull", image_digest])?;
                self.webui_verify(Some(&state))?;
                state.previous = state.current.take();
                state.phase = Phase::Updating;
                self.webui_save(&state)?;
                self.webui_verify_container(&current)?
                    .ok_or_else(ownership_error)?;
                self.webui_command(&["stop", "--time=20", &current.id])?;
                self.webui_verify_container(&current)?
                    .ok_or_else(ownership_error)?;
                self.webui_command(&[
                    "rename",
                    &current.id,
                    &format!("spark-open-webui-previous-{}", state.generation),
                ])?;
                let replacement = self
                    .webui_create(&mut state, image_digest, false)
                    .and_then(|()| self.webui_wait(state.current.as_ref().expect("created")));
                if !matches!(replacement, Ok(true)) {
                    // Without a persisted create receipt, preserve both containers for local recovery.
                    if state.pending_create {
                        return Err(ownership_error());
                    }
                    let restored = self.webui_rollback(&mut state)?;
                    return Ok(reply(
                        false,
                        if restored {
                            "OPEN_WEBUI_UPDATE_ROLLED_BACK"
                        } else {
                            "OPEN_WEBUI_ROLLBACK_FAILED"
                        },
                        Value::Null,
                    ));
                }
                // Persist health success before deleting the old container so crash recovery cannot attempt an impossible rollback.
                state.phase = Phase::Promoting;
                self.webui_save(&state)?;
                self.webui_remove_exact(&current)?;
                state.previous = None;
                state.phase = Phase::Ready;
                self.webui_save(&state)?;
                Ok(reply(
                    true,
                    "open_webui_updated",
                    json!({"state":"healthy"}),
                ))
            }
            PrivilegedOperation::RepairOpenWebUi { .. } => {
                let Some(mut state) = journal else {
                    return Ok(reply(false, "OPEN_WEBUI_NOT_INSTALLED", Value::Null));
                };
                if state.phase == Phase::Promoting {
                    let current = state.current.as_ref().ok_or_else(ownership_error)?;
                    let healthy = self.webui_wait(current)?;
                    if !healthy {
                        return Ok(reply(false, "OPEN_WEBUI_RECOVERY_REQUIRED", Value::Null));
                    }
                    if let Some(previous) = &state.previous {
                        self.webui_remove_exact(previous)?;
                    }
                    state.previous = None;
                    state.phase = Phase::Ready;
                    self.webui_save(&state)?;
                    return Ok(reply(
                        true,
                        "open_webui_repaired",
                        json!({"state":"healthy"}),
                    ));
                }
                if state.phase == Phase::Updating {
                    let healthy = self.webui_rollback(&mut state)?;
                    return Ok(reply(
                        healthy,
                        if healthy {
                            "open_webui_repaired"
                        } else {
                            "OPEN_WEBUI_ROLLBACK_FAILED"
                        },
                        Value::Null,
                    ));
                }
                let resumable_install = state.phase == Phase::Installing
                    && state
                        .current
                        .as_ref()
                        .is_some_and(|container| !container.bootstrap);
                if state.phase != Phase::Ready && !resumable_install {
                    return Ok(reply(false, "OPEN_WEBUI_RECOVERY_REQUIRED", Value::Null));
                }
                let current = state.current.clone().ok_or_else(ownership_error)?;
                let value = self
                    .webui_verify_container(&current)?
                    .ok_or_else(ownership_error)?;
                // A health check does not authorize restarting a deliberately stopped service.
                if value["State"]["Running"] != true {
                    return Ok(reply(
                        false,
                        "OPEN_WEBUI_INTENTIONALLY_STOPPED",
                        Value::Null,
                    ));
                }
                if self.open_webui_healthy() {
                    state.phase = Phase::Ready;
                    self.webui_save(&state)?;
                    return Ok(reply(true, "open_webui_current", Value::Null));
                }
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_err(|_| ownership_error())?
                    .as_secs();
                if state.last_repair_epoch != 0 && now.saturating_sub(state.last_repair_epoch) < 300
                {
                    return Ok(reply(false, "OPEN_WEBUI_REPAIR_COOLDOWN", Value::Null));
                }
                state.last_repair_epoch = now;
                self.webui_save(&state)?;
                self.webui_verify(Some(&state))?;
                self.webui_verify_container(&current)?
                    .ok_or_else(ownership_error)?;
                self.webui_command(&["restart", "--time=20", &current.id])?;
                let healthy = self.webui_wait(&current)?;
                if healthy {
                    state.phase = Phase::Ready;
                    self.webui_save(&state)?;
                }
                Ok(reply(
                    healthy,
                    if healthy {
                        "open_webui_repaired"
                    } else {
                        "OPEN_WEBUI_REPAIR_FAILED"
                    },
                    json!({"attempts":1,"retry_after_seconds":300}),
                ))
            }
            PrivilegedOperation::RemoveOpenWebUi { erase_data, .. } => {
                let Some(mut state) = journal else {
                    return Ok(reply(true, "open_webui_removed", Value::Null));
                };
                if state.phase == Phase::Removing && state.erase_data != *erase_data {
                    return Ok(reply(false, "OPEN_WEBUI_REMOVE_IN_PROGRESS", Value::Null));
                }
                state.phase = Phase::Removing;
                state.erase_data = *erase_data;
                self.webui_save(&state)?;
                for container in state.current.iter().chain(state.previous.iter()) {
                    self.webui_remove_exact(container)?;
                }
                state.current = None;
                state.previous = None;
                self.webui_save(&state)?;
                if *erase_data {
                    if let Some(volume) = &state.volume
                        && self.webui_inspect("volume", &volume.name)?.is_some()
                    {
                        self.webui_verify_volume(volume)?;
                        self.webui_command(&["volume", "rm", &volume.name])?;
                    }
                    state.volume = None;
                }
                state.phase = Phase::Removed;
                self.webui_save(&state)?;
                for name in ["gateway.env", "bootstrap.env"] {
                    let path = self.open_webui_root.join(name);
                    if path.exists() {
                        fs::remove_file(path)?;
                    }
                }
                Ok(reply(
                    true,
                    "open_webui_removed",
                    json!({"erase_data":erase_data}),
                ))
            }
            _ => unreachable!(),
        }
    }
}

#[cfg(test)]
#[path = "open_webui/tests.rs"]
mod tests;

mod journal;

impl DockerBackend {
    fn journal(&self) -> journal::OwnedJournal<'_> {
        journal::OwnedJournal {
            open_webui_root: &self.open_webui_root,
        }
    }
}

mod inspection;

impl DockerBackend {
    fn inspection(&self) -> inspection::DockerInspection<'_> {
        inspection::DockerInspection {
            docker_bin: &self.docker_bin,
            plan_only: self.plan_only,
            runner: self.appliance_command_runner.as_ref(),
        }
    }
}

mod volume;

impl DockerBackend {
    fn volume(&self) -> volume::VolumeProvisioner<'_> {
        volume::VolumeProvisioner {
            journal: self.journal(),
            docker: self.inspection(),
        }
    }
}

mod evidence;
use evidence::{
    Container, Journal, Phase, Volume, configuration, hash, private_metadata, valid_id,
};

mod adoption;

mod status;

mod creation;

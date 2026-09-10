use std::collections::HashMap;

use std::fs::{self, OpenOptions};

use std::io::{Read, Write};

use std::net::Ipv4Addr;

use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};

use std::path::PathBuf;

use std::sync::{Arc, Mutex, MutexGuard};

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::backend::{BackendError, DIRECT_PROFILE, NMCLI_BIN, TRAVEL_PROFILE, valid_ssid};

use crate::update::CommandRunner;

pub(crate) const NETWORK_ROLLBACK_DIRECTORY: &str = "/var/lib/spark-privd/network-rollbacks";

pub const NETWORK_ROLLBACK_JOURNAL_FILE: &str = "pending.json";

const NETWORK_ROLLBACK_JOURNAL_VERSION: u32 = 1;

const MAX_NETWORK_ROLLBACK_JOURNAL_BYTES: u64 = 256 * 1024;

const MAX_RETRY_DELAY: Duration = Duration::from_secs(5);

const MIN_RETRY_DELAY: Duration = Duration::from_millis(10);

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct NetworkRollback {
    pub(crate) commands: Vec<(String, Vec<String>)>,
    #[serde(default)]
    pub(crate) restore_ipv4: Option<StoredIpv4Configuration>,
}

impl NetworkRollback {
    pub(crate) fn commands(commands: Vec<(String, Vec<String>)>) -> Self {
        Self {
            commands,
            restore_ipv4: None,
        }
    }

    fn run(&self, runner: &dyn CommandRunner) -> Result<(), BackendError> {
        let mut failed = false;
        if let Some(configuration) = &self.restore_ipv4 {
            let addresses = configuration
                .addresses
                .iter()
                .map(|value| format!("{}/{}", value.address, value.prefix_length))
                .collect::<Vec<_>>()
                .join(",");
            let gateway = configuration
                .gateway
                .map(|value| value.to_string())
                .unwrap_or_default();
            let dns = configuration
                .dns_servers
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(",");
            let args = vec![
                "connection".into(),
                "modify".into(),
                "uuid".into(),
                configuration.connection_uuid.to_string(),
                "ipv4.method".into(),
                configuration.method.as_nmcli().into(),
                "ipv4.addresses".into(),
                addresses,
                "ipv4.gateway".into(),
                gateway,
                "ipv4.dns".into(),
                dns,
                "ipv4.ignore-auto-dns".into(),
                if configuration.ignore_auto_dns {
                    "yes".into()
                } else {
                    "no".into()
                },
            ];
            match runner.run(NMCLI_BIN, &args) {
                Ok(output) if output.success() => {}
                Ok(output) => {
                    tracing::error!(detail = %output.stderr_text(), "network IPv4 restore failed");
                    failed = true;
                }
                Err(error) => {
                    tracing::error!(%error, "network IPv4 restore failed");
                    failed = true;
                }
            }
        }
        for (program, arguments) in &self.commands {
            match runner.run(program, arguments) {
                Ok(output) if output.success() => {}
                Ok(output) => {
                    tracing::error!(detail = %output.stderr_text(), %program, "network failsafe command failed");
                    failed = true;
                }
                Err(error) => {
                    tracing::error!(%error, %program, "network failsafe command failed");
                    failed = true;
                }
            }
        }
        if failed {
            Err(BackendError::Failure(
                "one or more network failsafe commands failed".into(),
            ))
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct PendingNetworkRollback {
    expires_at_unix_millis: u64,
    rollback: NetworkRollback,
    #[serde(skip)]
    executing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NetworkChangeResolution {
    Resolved,
    Missing,
    Executing,
}

enum RollbackClaim {
    Claimed(NetworkRollback),
    Missing,
    Executing,
}

pub(crate) struct NetworkRollbackManager {
    pending: Arc<Mutex<HashMap<uuid::Uuid, PendingNetworkRollback>>>,
    timeout: Duration,
    retry_delay: Duration,
    store: NetworkRollbackStore,
    load_error: Arc<Mutex<Option<String>>>,
    runner: Arc<dyn CommandRunner>,
    mutation_guard: Mutex<()>,
}

impl NetworkRollbackManager {
    pub(crate) fn production(runner: Arc<dyn CommandRunner>) -> Self {
        Self::new(
            NetworkRollbackStore {
                directory: PathBuf::from(NETWORK_ROLLBACK_DIRECTORY),
                owner_uid: 0,
            },
            runner,
            Duration::from_secs(90),
        )
    }

    fn new(store: NetworkRollbackStore, runner: Arc<dyn CommandRunner>, timeout: Duration) -> Self {
        Self {
            pending: Arc::new(Mutex::new(HashMap::new())),
            timeout,
            retry_delay: retry_delay(timeout),
            store,
            load_error: Arc::new(Mutex::new(None)),
            runner,
            mutation_guard: Mutex::new(()),
        }
    }

    pub(crate) fn set_runner(&mut self, runner: Arc<dyn CommandRunner>) {
        self.runner = runner;
    }

    pub(crate) fn set_timeout(&mut self, timeout: Duration) {
        self.timeout = timeout;
        self.retry_delay = retry_delay(timeout);
    }

    pub(crate) fn use_test_store(&mut self, directory: PathBuf, owner_uid: u32) {
        self.store = NetworkRollbackStore {
            directory,
            owner_uid,
        };
        self.pending = Arc::new(Mutex::new(HashMap::new()));
        self.load_error = Arc::new(Mutex::new(None));
    }

    pub(crate) fn recover(&self) {
        match load_network_rollbacks(&self.store) {
            Ok(pending) => {
                let configuration_ids = pending.keys().copied().collect::<Vec<_>>();
                *self.pending.lock().expect("network rollback registry") = pending;
                for configuration_id in configuration_ids {
                    self.schedule(configuration_id);
                }
            }
            Err(error) => {
                tracing::error!(%error, "network rollback journal could not be recovered");
                *self.load_error.lock().expect("network rollback load state") =
                    Some(error.to_string());
            }
        }
    }

    pub(crate) fn begin_mutation(&self) -> Result<MutexGuard<'_, ()>, BackendError> {
        let guard = self
            .mutation_guard
            .lock()
            .map_err(|_| BackendError::Failure("network mutation lock is unavailable".into()))?;
        self.ensure_ready()?;
        ensure_journal_directory(&self.store)?;
        if !self
            .pending
            .lock()
            .expect("network rollback registry")
            .is_empty()
        {
            return Err(BackendError::Failure(
                "a pending network change must be resolved before another change".into(),
            ));
        }
        Ok(guard)
    }

    pub(crate) fn prepare(
        &self,
        configuration_id: uuid::Uuid,
        rollback: NetworkRollback,
        recovery_timeout: Duration,
    ) -> Result<(), BackendError> {
        self.ensure_ready()?;
        let pending = PendingNetworkRollback {
            expires_at_unix_millis: expiry(recovery_timeout),
            rollback,
            executing: false,
        };
        let mut changes = self.pending.lock().expect("network rollback registry");
        if !changes.is_empty() {
            return Err(BackendError::Failure(
                "a pending network change must be resolved before another change".into(),
            ));
        }
        changes.insert(configuration_id, pending);
        if let Err(error) = persist_network_rollbacks(&self.store, &changes) {
            changes.remove(&configuration_id);
            return Err(error);
        }
        Ok(())
    }

    pub(crate) fn register_after_mutation(
        &self,
        configuration_id: uuid::Uuid,
        rollback: NetworkRollback,
    ) -> Result<(), BackendError> {
        let recovery = rollback.clone();
        if let Err(error) = self.prepare(configuration_id, rollback, self.timeout) {
            let _ = recovery.run(self.runner.as_ref());
            return Err(error);
        }
        self.schedule(configuration_id);
        Ok(())
    }

    pub(crate) fn arm(
        &self,
        configuration_id: uuid::Uuid,
        timeout: Duration,
    ) -> Result<(), BackendError> {
        let mut changes = self.pending.lock().expect("network rollback registry");
        let pending = changes.get_mut(&configuration_id).ok_or_else(|| {
            BackendError::Failure("network rollback disappeared before activation".into())
        })?;
        if pending.executing {
            return Err(BackendError::Failure(
                "network rollback began before activation completed".into(),
            ));
        }
        let previous_expiry = pending.expires_at_unix_millis;
        pending.expires_at_unix_millis = expiry(timeout.min(self.timeout));
        if let Err(error) = persist_network_rollbacks(&self.store, &changes) {
            if let Some(pending) = changes.get_mut(&configuration_id) {
                pending.expires_at_unix_millis = previous_expiry;
            }
            return Err(error);
        }
        drop(changes);
        self.schedule(configuration_id);
        Ok(())
    }

    pub(crate) fn confirm(
        &self,
        configuration_id: uuid::Uuid,
    ) -> Result<NetworkChangeResolution, BackendError> {
        self.ensure_ready()?;
        let mut changes = self.pending.lock().expect("network rollback registry");
        match changes.get(&configuration_id) {
            Some(pending) if pending.executing => return Ok(NetworkChangeResolution::Executing),
            Some(_) => {}
            None => return Ok(NetworkChangeResolution::Missing),
        }
        let removed = changes
            .remove(&configuration_id)
            .expect("pending rollback checked above");
        if let Err(error) = persist_network_rollbacks(&self.store, &changes) {
            changes.insert(configuration_id, removed);
            return Err(error);
        }
        Ok(NetworkChangeResolution::Resolved)
    }

    pub(crate) fn rollback(
        &self,
        configuration_id: uuid::Uuid,
    ) -> Result<NetworkChangeResolution, BackendError> {
        self.ensure_ready()?;
        let claim = claim_network_rollback(&self.pending, configuration_id);
        let rollback = match claim {
            RollbackClaim::Claimed(rollback) => rollback,
            RollbackClaim::Missing => return Ok(NetworkChangeResolution::Missing),
            RollbackClaim::Executing => return Ok(NetworkChangeResolution::Executing),
        };
        if let Err(error) = rollback.run(self.runner.as_ref()) {
            mark_network_rollback_due(&self.pending, &self.store, configuration_id);
            self.schedule(configuration_id);
            return Err(error);
        }
        if let Err(error) = finish_network_rollback(&self.pending, &self.store, configuration_id) {
            mark_network_rollback_due(&self.pending, &self.store, configuration_id);
            self.schedule(configuration_id);
            return Err(error);
        }
        Ok(NetworkChangeResolution::Resolved)
    }

    fn ensure_ready(&self) -> Result<(), BackendError> {
        match self
            .load_error
            .lock()
            .expect("network rollback load state")
            .clone()
        {
            Some(error) => Err(BackendError::Failure(format!(
                "network rollback journal is unavailable: {error}"
            ))),
            None => Ok(()),
        }
    }

    fn schedule(&self, configuration_id: uuid::Uuid) {
        schedule_network_rollback(
            self.pending.clone(),
            self.store.clone(),
            self.runner.clone(),
            self.retry_delay,
            configuration_id,
        );
    }
}

fn retry_delay(timeout: Duration) -> Duration {
    timeout.min(MAX_RETRY_DELAY).max(MIN_RETRY_DELAY)
}

fn unix_millis_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

fn expiry(timeout: Duration) -> u64 {
    unix_millis_now().saturating_add(timeout.as_millis().min(u128::from(u64::MAX)) as u64)
}

fn claim_network_rollback(
    pending: &Arc<Mutex<HashMap<uuid::Uuid, PendingNetworkRollback>>>,
    configuration_id: uuid::Uuid,
) -> RollbackClaim {
    let mut changes = pending.lock().expect("network rollback registry");
    let Some(change) = changes.get_mut(&configuration_id) else {
        return RollbackClaim::Missing;
    };
    if change.executing {
        return RollbackClaim::Executing;
    }
    change.executing = true;
    RollbackClaim::Claimed(change.rollback.clone())
}

fn mark_network_rollback_due(
    pending: &Arc<Mutex<HashMap<uuid::Uuid, PendingNetworkRollback>>>,
    store: &NetworkRollbackStore,
    configuration_id: uuid::Uuid,
) {
    let mut changes = pending.lock().expect("network rollback registry");
    if let Some(change) = changes.get_mut(&configuration_id) {
        change.executing = false;
        change.expires_at_unix_millis = unix_millis_now();
    }
    if let Err(error) = persist_network_rollbacks(store, &changes) {
        tracing::error!(%error, %configuration_id, "network rollback retry state could not be persisted");
    }
}

fn finish_network_rollback(
    pending: &Arc<Mutex<HashMap<uuid::Uuid, PendingNetworkRollback>>>,
    store: &NetworkRollbackStore,
    configuration_id: uuid::Uuid,
) -> Result<(), BackendError> {
    let mut changes = pending.lock().expect("network rollback registry");
    let Some(mut removed) = changes.remove(&configuration_id) else {
        return Ok(());
    };
    if let Err(error) = persist_network_rollbacks(store, &changes) {
        removed.executing = false;
        changes.insert(configuration_id, removed);
        return Err(error);
    }
    Ok(())
}

fn schedule_network_rollback(
    pending: Arc<Mutex<HashMap<uuid::Uuid, PendingNetworkRollback>>>,
    store: NetworkRollbackStore,
    runner: Arc<dyn CommandRunner>,
    retry_delay: Duration,
    configuration_id: uuid::Uuid,
) {
    std::thread::spawn(move || {
        loop {
            let delay = pending
                .lock()
                .expect("network rollback registry")
                .get(&configuration_id)
                .map(|rollback| {
                    Duration::from_millis(
                        rollback
                            .expires_at_unix_millis
                            .saturating_sub(unix_millis_now()),
                    )
                });
            let Some(delay) = delay else {
                return;
            };
            if !delay.is_zero() {
                std::thread::sleep(delay);
                continue;
            }
            match claim_network_rollback(&pending, configuration_id) {
                RollbackClaim::Missing | RollbackClaim::Executing => return,
                RollbackClaim::Claimed(rollback) => {
                    let result = rollback
                        .run(runner.as_ref())
                        .and_then(|_| finish_network_rollback(&pending, &store, configuration_id));
                    match result {
                        Ok(()) => return,
                        Err(error) => {
                            tracing::error!(%error, %configuration_id, "network failsafe rollback failed; retrying");
                            mark_network_rollback_due(&pending, &store, configuration_id);
                            std::thread::sleep(retry_delay);
                        }
                    }
                }
            }
        }
    });
}

#[cfg(test)]
#[path = "network_rollback/tests.rs"]
mod tests;

mod configuration;
use configuration::valid_network_rollback;
pub(crate) use configuration::{
    StoredIpv4Address, StoredIpv4Configuration, StoredIpv4Method, valid_stored_ipv4,
};

mod journal;
use journal::{
    NetworkRollbackStore, ensure_journal_directory, load_network_rollbacks,
    persist_network_rollbacks,
};

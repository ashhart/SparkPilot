//! Run unprivileged project containers through typed privileged operations, without a Docker socket and with default-deny networking.

use std::path::Path;
use std::sync::Mutex;

use serde::Serialize;
use uuid::Uuid;

use crate::devcontainer::DevcontainerPlan;

/// A launched project container assigned to one worktree.
#[derive(Debug, Clone, Serialize)]
pub struct RunningContainer {
    pub id: String,
    pub project_id: Uuid,
    /// Loopback-forwarded ports (each mapped inside the container).
    pub forward_ports: Vec<u16>,
    pub worktree_path: String,
}

pub trait ContainerBoundary: Send + Sync {
    /// Start from a validated plan using its already-pinned image digest.
    fn start(
        &self,
        plan: &DevcontainerPlan,
        project_id: Uuid,
        worktree_path: &Path,
    ) -> Result<RunningContainer, String>;
    fn stop(&self, container_id: &str) -> Result<(), String>;
    fn running(&self) -> Result<Vec<String>, String>;
}

/// Test double recording launch requests; never used in production wiring.
#[derive(Debug, Default)]
pub struct FakeContainerBoundary {
    log: Mutex<Vec<String>>,
}

impl FakeContainerBoundary {
    pub fn calls(&self) -> Vec<String> {
        self.log.lock().expect("log").clone()
    }
}

impl ContainerBoundary for FakeContainerBoundary {
    fn start(
        &self,
        plan: &DevcontainerPlan,
        _project_id: Uuid,
        worktree_path: &Path,
    ) -> Result<RunningContainer, String> {
        self.log.lock().expect("log").push(format!(
            "start {} {}",
            plan.image_digest,
            worktree_path.display()
        ));
        Ok(RunningContainer {
            id: Uuid::new_v4().to_string(),
            project_id: _project_id,
            forward_ports: plan.forward_ports.clone(),
            worktree_path: worktree_path.display().to_string(),
        })
    }

    fn stop(&self, container_id: &str) -> Result<(), String> {
        self.log
            .lock()
            .expect("log")
            .push(format!("stop {container_id}"));
        Ok(())
    }

    fn running(&self) -> Result<Vec<String>, String> {
        Ok(Vec::new())
    }
}

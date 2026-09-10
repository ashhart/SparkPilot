//! Run typed, audited agent tools inside project containers and persist change-review decisions.

use std::collections::VecDeque;

use std::path::{Path, PathBuf};

use std::sync::Arc;

use parking_lot::Mutex;

use serde::{Deserialize, Serialize};

use serde_json::json;

use sha2::Digest;

use uuid::Uuid;

use crate::events::EventBus;

use crate::jobs::JobService;

use crate::project::ProjectManager;

use crate::store;

/// Maximum bytes a tool may return or a brain may read per call.
pub const TOOL_OUTPUT_CAP: usize = 64 * 1024;

/// Bounded loop: a change never runs more tool calls than this.
pub const MAX_TOOL_CALLS: usize = 200;

/// Bounded task text (mirrors the contract).
pub const MAX_TASK_CHARS: usize = 20_000;

/// Diff/test command allowlist baseline (policy overrides add entries).
pub const DEFAULT_COMMAND_ALLOWLIST: &[&str] = &[
    "cargo test",
    "cargo fmt --check",
    "swift test",
    "npm test",
    "python3 -m pytest",
];

#[derive(Clone)]
pub struct AgentService {
    pub projects: Arc<ProjectManager>,
    pub jobs: JobService,
    pub events: EventBus,
    pub node_id: String,
    /// Serialize access to brain state across concurrent changes.
    brain: Arc<Mutex<Box<dyn AgentBrain>>>,
    runtime: Arc<dyn AgentToolExecutor>,
}

impl AgentService {
    pub fn new(
        projects: Arc<ProjectManager>,
        jobs: JobService,
        events: EventBus,
        node_id: String,
        brain: Box<dyn AgentBrain>,
        runtime: Arc<dyn AgentToolExecutor>,
    ) -> Self {
        Self {
            projects,
            jobs,
            events,
            node_id,
            brain: Arc::new(Mutex::new(brain)),
            runtime,
        }
    }

    /// Create a durable change and worktree, then run its worker asynchronously.
    pub fn start_change(
        &self,
        operation_id: Uuid,
        project_id: &Uuid,
        task: &str,
        base_commit: Option<&str>,
    ) -> Result<Uuid, String> {
        if task.is_empty() || task.len() > MAX_TASK_CHARS {
            return Err("task must be 1..=20000 characters".into());
        }
        let project = self.projects.get(project_id)?;
        // Reserve worker capacity before acquiring a lease so refused changes have no lease to unwind.
        let slot = self.jobs.workers().try_admit().ok_or_else(|| {
            crate::jobs::LeaseError::Overloaded(self.jobs.worker_metrics().capacity).to_string()
        })?;
        let lease = self
            .jobs
            .acquire_lease(self.projects.db.clone(), operation_id)
            .map_err(|error| error.to_string())?;
        if lease.is_cancelled() {
            lease.settle_failed("OPERATION_CANCELLED");
            return Err("OPERATION_CANCELLED".into());
        }
        let change_id = Uuid::new_v4();
        let inserted = {
            let conn = self.projects.db.lock();
            store::insert_change(
                &conn,
                &store::ChangeRow {
                    id: change_id,
                    project_id: *project_id,
                    operation_id,
                    worktree_branch: String::new(),
                    base_commit: base_commit.unwrap_or("").to_owned(),
                    task: task.to_owned(),
                    status: "creating".into(),
                    diff_summary_json: "{}".into(),
                    test_summary_json: "{}".into(),
                    audit_json: "[]".into(),
                    head_commit: None,
                    protected_head_commit: None,
                    review_digest: None,
                    review_evidence_json: "{}".into(),
                    merged_commit: None,
                    created_at: String::new(),
                    updated_at: String::new(),
                },
            )
            .map_err(|e| e.to_string())
        };
        if let Err(error) = inserted {
            lease.settle_failed("CHANGE_CREATE_FAILED");
            return Err(error);
        }

        let service = self.clone();
        let task = task.to_owned();
        let base_commit = base_commit.map(str::to_owned);
        std::thread::spawn(move || {
            let _slot = slot;
            service.change_worker(
                lease,
                change_id,
                operation_id,
                project,
                &task,
                base_commit.as_deref(),
            );
        });
        Ok(change_id)
    }

    fn change_worker(
        &self,
        lease: crate::jobs::OperationLease,
        change_id: Uuid,
        operation_id: Uuid,
        project: crate::project::ProjectView,
        task: &str,
        base_commit: Option<&str>,
    ) {
        let outcome = self.run_change(change_id, operation_id, &project, task, base_commit);
        match outcome {
            Ok(()) => {
                lease.settle_succeeded(&json!({ "change": change_id, "review_ready": true }));
            }
            Err(e) => {
                let conn = self.projects.db.lock();
                let _ = store::update_change_status(&conn, &change_id, "failed");
                drop(conn);
                lease.settle_failed(&e);
            }
        }
        let conn = self.projects.db.lock();
        let status = store::change_row(&conn, &change_id)
            .ok()
            .flatten()
            .map(|c| c.status)
            .unwrap_or_else(|| "failed".into());
        // Publish change events only to the owning project's members.
        self.events.emit_scoped(
            Some(&conn),
            &self.node_id,
            Some(operation_id),
            if status == "review" {
                "change.review_ready"
            } else {
                "change.failed"
            },
            if status == "review" { "info" } else { "error" },
            json!({ "change_id": change_id, "status": status }),
            crate::events::Visibility::project(project.id),
        );
    }

    fn run_change(
        &self,
        change_id: Uuid,
        operation_id: Uuid,
        project: &crate::project::ProjectView,
        task: &str,
        base_commit: Option<&str>,
    ) -> Result<(), String> {
        let created = self
            .projects
            .create_worktree(project, base_commit, Some(operation_id))
            .map_err(|e| e.to_string())?;
        let worktree = created.path;
        let branch = created.branch;
        let resolved_base = created.base_commit;
        let container = created.container.ok_or_else(|| {
            "PROJECT_SANDBOX_UNAVAILABLE: agent tools require a validated project container"
                .to_owned()
        })?;
        {
            let conn = self.projects.db.lock();
            crate::store::set_change_branch(&conn, &change_id, &branch)
                .map_err(|e| e.to_string())?;
            store::update_change_status(&conn, &change_id, "planning")
                .map_err(|e| e.to_string())?;
        }

        let mut last_output = None;
        let mut calls = 0usize;
        let mut tool_evidence = Vec::new();
        let mut test_evidence = Vec::new();
        loop {
            calls += 1;
            if calls > MAX_TOOL_CALLS {
                return Err("agent exceeded tool-call budget".into());
            }
            let next = {
                let mut brain = self.brain.lock();
                brain
                    .step(&WorktreeContext {
                        task: task.to_owned(),
                        worktree: worktree.clone(),
                        last_output: last_output.clone(),
                    })
                    .map_err(|e| e.to_string())?
            };
            let Some(call) = next else { break };
            let result = self.runtime.execute(
                &ToolExecutionTarget {
                    project_id: project.id,
                    container_id: &container.id,
                    worktree: &worktree,
                },
                &call,
            );
            let call_json = audited_call_json(&call);
            {
                let conn = self.projects.db.lock();
                let _ = store::insert_agent_call(
                    &conn,
                    &change_id,
                    &result.tool,
                    &call_json,
                    if result.ok { "ok" } else { "failed" },
                );
            }
            let conn = self.projects.db.lock();
            self.events.emit_scoped(
                Some(&conn),
                &self.node_id,
                Some(operation_id),
                "agent.tool",
                if result.ok { "info" } else { "warning" },
                json!({ "change_id": change_id, "tool": result.tool, "ok": result.ok }),
                crate::events::Visibility::project(project.id),
            );
            last_output = Some(if result.output.is_empty() {
                "(no output)".into()
            } else {
                result.output.clone()
            });
            tool_evidence.push(crate::change_evidence::ToolEvidence {
                sequence: calls as u16,
                tool: result.tool.clone(),
                outcome: if result.denied.is_some() {
                    "denied".into()
                } else if result.ok {
                    "ok".into()
                } else {
                    "failed".into()
                },
            });
            if let AgentToolCall::RunCommand { command } = &call {
                test_evidence.push(crate::change_evidence::TestEvidence {
                    command: command.clone(),
                    status: if result.ok { "passed" } else { "failed" }.into(),
                    exit_code: result.exit_code.unwrap_or(if result.ok { 0 } else { 1 }),
                    output_digest: hex::encode(sha2::Sha256::digest(result.output.as_bytes())),
                });
            }
            if !result.ok {
                return Err(format!("agent tool failed: {}", result.tool));
            }
        }

        let evidence = crate::change_evidence::ReviewEvidence::capture(
            &self.projects,
            project,
            &worktree,
            &resolved_base,
            test_evidence,
            tool_evidence,
        )?;
        let review_digest = evidence.digest()?;
        let evidence_json = serde_json::to_string(&evidence).map_err(|error| error.to_string())?;
        {
            let conn = self.projects.db.lock();
            let advanced = store::set_change_review_evidence(
                &conn,
                &change_id,
                &evidence.base_commit,
                &evidence.head_commit,
                &evidence.protected_head_commit,
                &review_digest,
                &evidence_json,
            )
            .map_err(|e| e.to_string())?;
            if !advanced {
                return Err("CHANGE_NOT_EDITABLE".into());
            }
        }
        Ok(())
    }

    /// Resolve changes against their stored project ID and conceal cross-project mismatches as not found.
    pub fn change_in_project(
        &self,
        project_id: &Uuid,
        change_id: &Uuid,
    ) -> Result<store::ChangeRow, String> {
        let conn = self.projects.db.lock();
        let row = store::change_row(&conn, change_id)
            .map_err(|e| e.to_string())?
            .ok_or("CHANGE_NOT_FOUND")?;
        if row.project_id != *project_id {
            return Err("CHANGE_NOT_FOUND".to_owned());
        }
        Ok(row)
    }

    pub fn get_change(&self, id: &Uuid) -> Result<store::ChangeRow, String> {
        let conn = self.projects.db.lock();
        store::change_row(&conn, id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "CHANGE_NOT_FOUND".to_owned())
    }

    pub fn list_changes(&self, project_id: &Uuid) -> Result<Vec<store::ChangeRow>, String> {
        let conn = self.projects.db.lock();
        store::change_rows(&conn, project_id).map_err(|e| e.to_string())
    }

    pub fn change_calls(&self, change_id: &Uuid) -> Result<Vec<(String, String, String)>, String> {
        let conn = self.projects.db.lock();
        store::agent_calls(&conn, change_id).map_err(|e| e.to_string())
    }
}

mod tool_runtime;
pub(crate) use tool_runtime::command_is_allowlisted;
pub use tool_runtime::{
    AgentPolicy, AgentToolCall, AgentToolExecutor, GitOp, ToolExecutionTarget, ToolResult,
    ToolRuntime,
};

mod brain;
use brain::audited_call_json;
pub use brain::{AgentBrain, ScriptedBrain, WorktreeContext, parse_diff_stat};

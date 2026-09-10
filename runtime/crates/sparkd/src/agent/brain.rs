use super::*;

/// What a brain sees before choosing its next call.
#[derive(Debug, Clone)]
pub struct WorktreeContext {
    pub task: String,
    pub worktree: PathBuf,
    /// Output of the previous call (or empty).
    pub last_output: Option<String>,
}

/// Replaceable agent-decision interface for model-driven execution and deterministic tests.
pub trait AgentBrain: Send + Sync {
    fn step(&mut self, context: &WorktreeContext) -> Result<Option<AgentToolCall>, String>;
}

/// Scripted brain used by the acceptance suite and `--agent-brain scripted`.
pub struct ScriptedBrain {
    pub(super) calls: VecDeque<AgentToolCall>,
}

impl ScriptedBrain {
    pub fn plan(calls: Vec<AgentToolCall>) -> Self {
        Self {
            calls: calls.into(),
        }
    }
}

impl AgentBrain for ScriptedBrain {
    fn step(&mut self, _context: &WorktreeContext) -> Result<Option<AgentToolCall>, String> {
        Ok(self.calls.pop_front())
    }
}

/// Sums up a `git diff --stat` line like `1 file changed, 3 insertions(+)`.
pub fn parse_diff_stat(line: &str) -> (u64, u64, u64) {
    let file_count = line
        .split_whitespace()
        .next()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let insertions = line
        .split("insertion")
        .next()
        .and_then(|s| s.split_whitespace().next())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let deletions = line
        .split("deletion")
        .next()
        .and_then(|s| s.split_whitespace().next())
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    (file_count, insertions, deletions)
}

pub(super) fn audited_call_json(call: &AgentToolCall) -> String {
    let value = match call {
        AgentToolCall::ReadFile { path } => json!({ "path": path }),
        AgentToolCall::SearchFiles { path, .. } => json!({ "path": path }),
        AgentToolCall::WriteFile { path, content } => json!({
            "path": path,
            "content_bytes": content.len(),
            "content_sha256": hex::encode(sha2::Sha256::digest(content.as_bytes())),
        }),
        AgentToolCall::DeleteFile { path } => json!({ "path": path }),
        AgentToolCall::RunCommand { command } => json!({ "command": command }),
        AgentToolCall::Git { op } => match op {
            GitOp::Status => json!({ "operation": "status" }),
            GitOp::Diff => json!({ "operation": "diff" }),
            GitOp::DiffStat => json!({ "operation": "diff_stat" }),
            GitOp::Log { count } => json!({ "operation": "log", "count": count }),
            GitOp::Add { path } => json!({ "operation": "add", "path": path }),
            GitOp::Commit { message } => json!({ "operation": "commit", "message": message }),
        },
    };
    value.to_string()
}

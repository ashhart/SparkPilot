use super::*;

/// Constrain typed file, Git and command tools to the agent worktree and command allowlist.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tool", rename_all = "snake_case")]
pub enum AgentToolCall {
    ReadFile { path: String },
    SearchFiles { path: String, pattern: String },
    WriteFile { path: String, content: String },
    DeleteFile { path: String },
    RunCommand { command: String },
    Git { op: GitOp },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum GitOp {
    Status,
    Diff,
    DiffStat,
    Log {
        count: u8,
    },
    /// Stage an explicitly named worktree-relative path.
    Add {
        path: String,
    },
    Commit {
        message: String,
    },
}

/// One tool execution result (output bounded).
#[derive(Debug, Clone, Serialize)]
pub struct ToolResult {
    pub tool: String,
    pub ok: bool,
    pub output: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denied: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<u8>,
}

pub struct ToolExecutionTarget<'a> {
    pub project_id: Uuid,
    pub container_id: &'a str,
    pub worktree: &'a Path,
}

pub trait AgentToolExecutor: Send + Sync {
    fn execute(&self, target: &ToolExecutionTarget<'_>, call: &AgentToolCall) -> ToolResult;
}

/// Per-project agent policy: which commands are allowed, call budget.
#[derive(Debug, Clone, Default)]
pub struct AgentPolicy {
    pub allowlist_commands: Vec<String>,
}

/// Unprivileged tool executor confined to one worktree directory.
pub struct ToolRuntime {
    pub(super) policy: AgentPolicy,
}

impl Default for ToolRuntime {
    fn default() -> Self {
        Self::new(AgentPolicy::default())
    }
}

/// Match the complete allowed argument vector; extra arguments can redirect permitted tools outside the worktree.
pub(crate) fn command_is_allowlisted(trimmed: &str, allowlist: &[String]) -> bool {
    allowlist.iter().any(|allowed| trimmed == allowed.trim())
}

impl ToolRuntime {
    pub fn new(policy: AgentPolicy) -> Self {
        Self { policy }
    }

    pub fn with_default_commands() -> Self {
        Self::new(AgentPolicy {
            allowlist_commands: DEFAULT_COMMAND_ALLOWLIST
                .iter()
                .map(|c| (*c).to_owned())
                .collect(),
        })
    }

    fn path_error(error: crate::beneath::BeneathError) -> String {
        format!("rejected: {error}")
    }

    /// Execute one call against the worktree. Never uses a shell.
    fn execute_local(&self, worktree: &Path, call: &AgentToolCall) -> ToolResult {
        let (label, result): (&str, Result<String, String>) = match call {
            AgentToolCall::ReadFile { path } => ("read_file", self.read(worktree, path)),
            AgentToolCall::SearchFiles { path, pattern } => {
                ("search_files", self.search(worktree, path, pattern))
            }
            AgentToolCall::WriteFile { path, content } => {
                ("write_file", self.write(worktree, path, content))
            }
            AgentToolCall::DeleteFile { path } => ("delete_file", self.delete(worktree, path)),
            AgentToolCall::RunCommand { command } => {
                ("run_command", self.run_command(worktree, command))
            }
            AgentToolCall::Git { op } => ("git", self.git(worktree, op)),
        };
        match result {
            Ok(text) => ToolResult {
                tool: label.to_owned(),
                ok: true,
                output: text,
                denied: None,
                exit_code: matches!(call, AgentToolCall::RunCommand { .. }).then_some(0),
            },
            Err(message) => ToolResult {
                tool: label.to_owned(),
                ok: false,
                denied: message.starts_with("rejected").then(|| message.clone()),
                output: message,
                exit_code: matches!(call, AgentToolCall::RunCommand { .. }).then_some(1),
            },
        }
    }

    fn read(&self, worktree: &Path, path: &str) -> Result<String, String> {
        let bytes = crate::beneath::read_beneath_bounded(worktree, path, TOOL_OUTPUT_CAP)
            .map_err(Self::path_error)?;
        String::from_utf8(bytes).map_err(|e| format!("failed: not UTF-8: {e}"))
    }

    fn search(&self, worktree: &Path, path: &str, pattern: &str) -> Result<String, String> {
        let prefix = if path == "." {
            String::new()
        } else {
            crate::beneath::safe_components(path)
                .map_err(Self::path_error)?
                .join("/")
        };
        if !prefix.is_empty() {
            let metadata =
                crate::beneath::metadata_beneath(worktree, &prefix).map_err(Self::path_error)?;
            if !metadata.is_dir() {
                return Err("failed: search path is not a directory".into());
            }
        }
        let mut hits = Vec::new();
        let entries = crate::beneath::list_beneath(worktree, 64, 2049).map_err(Self::path_error)?;
        if entries.len() > 2048 {
            return Err("failed: search budget exceeded".into());
        }
        let prefix_with_separator = format!("{prefix}/");
        for entry in entries {
            if !prefix.is_empty() && !entry.relative_path.starts_with(&prefix_with_separator) {
                continue;
            }
            if let Ok(bytes) = crate::beneath::read_beneath_bounded(
                worktree,
                &entry.relative_path,
                TOOL_OUTPUT_CAP,
            ) && String::from_utf8_lossy(&bytes).contains(pattern)
            {
                hits.push(entry.relative_path);
            }
            if hits.len() >= 64 {
                break;
            }
        }
        Ok(if hits.is_empty() {
            "no matches".into()
        } else {
            hits.join("\n")
        })
    }

    fn write(&self, worktree: &Path, path: &str, content: &str) -> Result<String, String> {
        if content.len() > TOOL_OUTPUT_CAP {
            return Err("failed: content exceeds output cap".into());
        }
        let components = crate::beneath::safe_components(path).map_err(Self::path_error)?;
        if components.len() > 1 {
            crate::beneath::create_dir_all_beneath(
                worktree,
                &components[..components.len() - 1].join("/"),
            )
            .map_err(Self::path_error)?;
        }
        crate::beneath::write_beneath(worktree, path, content.as_bytes())
            .map_err(Self::path_error)?;
        Ok(format!("ok: wrote {} bytes", content.len()))
    }

    fn delete(&self, worktree: &Path, path: &str) -> Result<String, String> {
        crate::beneath::remove_file_beneath(worktree, path).map_err(Self::path_error)?;
        Ok("ok: deleted".into())
    }

    fn run_command(&self, worktree: &Path, command: &str) -> Result<String, String> {
        if command.len() > 512 {
            return Err("rejected: command too long".into());
        }
        let trimmed = command.trim();
        if !command_is_allowlisted(trimmed, &self.policy.allowlist_commands) {
            return Err(format!("rejected: command not allowlisted ({trimmed})"));
        }
        // No shell: split on whitespace and exec the exact command.
        let parts: Vec<&str> = trimmed.split_whitespace().collect();
        let (program, args) = match parts.split_first() {
            Some(split) => split,
            None => return Err("rejected: empty command".into()),
        };
        let output = std::process::Command::new(program)
            .args(args)
            .current_dir(worktree)
            .output()
            .map_err(|e| format!("failed: command could not start: {e}"))?;
        let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
        if !output.status.success() {
            text.push_str(&String::from_utf8_lossy(&output.stderr));
        }
        if text.len() > TOOL_OUTPUT_CAP {
            text.truncate(TOOL_OUTPUT_CAP);
            text.push_str("\n[output truncated]");
        }
        if !output.status.success() {
            return Err(if text.is_empty() {
                "failed: command exited non-zero".into()
            } else {
                text
            });
        }
        Ok(text)
    }

    /// Validate a git operand path stays relative to the worktree.
    pub(crate) fn confine_relative(path: &str) -> Result<(), String> {
        if path.is_empty() || path.contains("..") || path.starts_with('/') {
            return Err(format!("rejected: git path not allowed: {path:?}"));
        }
        Ok(())
    }

    fn git(&self, worktree: &Path, op: &GitOp) -> Result<String, String> {
        let mut args: Vec<String> = Vec::new();
        match op {
            GitOp::Status => args.extend([
                "status".into(),
                "--porcelain=v1".into(),
                "--untracked-files=all".into(),
            ]),
            GitOp::Diff => args.push("diff".into()),
            GitOp::DiffStat => args.extend(["diff".into(), "--stat".into(), "HEAD".into()]),
            GitOp::Add { path } => {
                Self::confine_relative(path)?;
                args.extend(["add".into(), "--".into(), path.clone()])
            }
            GitOp::Log { count } => args.extend([
                "log".into(),
                "--oneline".into(),
                "-n".into(),
                count.to_string(),
            ]),
            GitOp::Commit { message } => args.extend([
                "commit".into(),
                "--quiet".into(),
                "-m".into(),
                message.clone(),
            ]),
        }
        let output = std::process::Command::new("git")
            .args(&args)
            .current_dir(worktree)
            .output()
            .map_err(|e| format!("failed: git could not start: {e}"))?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
        }
        let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
        if text.len() > TOOL_OUTPUT_CAP {
            text.truncate(TOOL_OUTPUT_CAP);
        }
        Ok(text)
    }
}

/// Emulate container worktrees in integration tests; production uses the privileged executor without a host fallback.
impl AgentToolExecutor for ToolRuntime {
    fn execute(&self, target: &ToolExecutionTarget<'_>, call: &AgentToolCall) -> ToolResult {
        self.execute_local(target.worktree, call)
    }
}

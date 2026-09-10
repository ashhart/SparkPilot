//! Execute production agent tools through the privileged project-container boundary without a host fallback.

use uuid::Uuid;

use crate::agent::{
    AgentPolicy, AgentToolCall, AgentToolExecutor, GitOp, TOOL_OUTPUT_CAP, ToolExecutionTarget,
    ToolResult, ToolRuntime,
};

pub struct PrivilegedToolRuntime {
    client: crate::privd::PrivilegedClient,
    policy: AgentPolicy,
}

impl PrivilegedToolRuntime {
    pub fn new(client: crate::privd::PrivilegedClient, policy: AgentPolicy) -> Self {
        Self { client, policy }
    }

    fn command_argv(&self, command: &str) -> Result<Vec<String>, String> {
        if command.len() > 512 {
            return Err("rejected: command too long".into());
        }
        let trimmed = command.trim();
        if !crate::agent::command_is_allowlisted(trimmed, &self.policy.allowlist_commands) {
            return Err(format!("rejected: command not allowlisted ({trimmed})"));
        }
        let argv = trimmed
            .split_whitespace()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if argv.is_empty() {
            return Err("rejected: empty command".into());
        }
        Ok(argv)
    }

    fn operation(
        &self,
        call: &AgentToolCall,
    ) -> Result<spark_privd::protocol::ProjectToolOperation, String> {
        use spark_privd::protocol::{ProjectGitOperation, ProjectToolOperation};
        Ok(match call {
            AgentToolCall::ReadFile { path } => {
                ProjectToolOperation::ReadFile { path: path.clone() }
            }
            AgentToolCall::SearchFiles { path, pattern } => ProjectToolOperation::SearchFiles {
                path: path.clone(),
                pattern: pattern.clone(),
            },
            AgentToolCall::WriteFile { path, content } => ProjectToolOperation::WriteFile {
                path: path.clone(),
                content: spark_privd::protocol::SecretString::new(content.clone()),
            },
            AgentToolCall::DeleteFile { path } => {
                ProjectToolOperation::DeleteFile { path: path.clone() }
            }
            AgentToolCall::RunCommand { command } => ProjectToolOperation::RunCommand {
                argv: self.command_argv(command)?,
            },
            AgentToolCall::Git { op } => ProjectToolOperation::Git {
                operation: match op {
                    GitOp::Status => ProjectGitOperation::Status,
                    GitOp::Diff => ProjectGitOperation::Diff,
                    GitOp::DiffStat => ProjectGitOperation::DiffStat,
                    GitOp::Log { count } => ProjectGitOperation::Log { count: *count },
                    GitOp::Add { path } => {
                        ToolRuntime::confine_relative(path)?;
                        ProjectGitOperation::Add { path: path.clone() }
                    }
                    GitOp::Commit { message } => ProjectGitOperation::Commit {
                        message: message.clone(),
                    },
                },
            },
        })
    }
}

impl AgentToolExecutor for PrivilegedToolRuntime {
    fn execute(&self, target: &ToolExecutionTarget<'_>, call: &AgentToolCall) -> ToolResult {
        let label = match call {
            AgentToolCall::ReadFile { .. } => "read_file",
            AgentToolCall::SearchFiles { .. } => "search_files",
            AgentToolCall::WriteFile { .. } => "write_file",
            AgentToolCall::DeleteFile { .. } => "delete_file",
            AgentToolCall::RunCommand { .. } => "run_command",
            AgentToolCall::Git { .. } => "git",
        };
        let operation = match self.operation(call) {
            Ok(operation) => operation,
            Err(message) => {
                return ToolResult {
                    tool: label.into(),
                    ok: false,
                    output: message.clone(),
                    denied: Some(message),
                    exit_code: None,
                };
            }
        };
        let response =
            self.client
                .call(spark_privd::protocol::PrivilegedOperation::RunProjectTool {
                    request_id: Uuid::new_v4(),
                    project_id: target.project_id,
                    container_id: target.container_id.to_owned(),
                    tool: operation,
                });
        match response {
            Ok(response) if response.accepted => {
                let ok = response
                    .details
                    .get("ok")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                let output = response
                    .details
                    .get("output")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(TOOL_OUTPUT_CAP)
                    .collect();
                ToolResult {
                    tool: label.into(),
                    ok,
                    output,
                    denied: None,
                    exit_code: response
                        .details
                        .get("exit_code")
                        .and_then(serde_json::Value::as_u64)
                        .and_then(|code| u8::try_from(code).ok()),
                }
            }
            Ok(response) => ToolResult {
                tool: label.into(),
                ok: false,
                output: response.message,
                denied: Some(response.code),
                exit_code: None,
            },
            Err(error) => ToolResult {
                tool: label.into(),
                ok: false,
                output: format!("project container tool failed: {error}"),
                denied: None,
                exit_code: None,
            },
        }
    }
}

//! Typed project-container tool execution.

use std::io::Write as _;
use std::path::{Component, Path};
use std::process::{Command, Stdio};

use crate::backend::BackendError;
use crate::protocol::{PrivilegedResponse, ProjectGitOperation, ProjectToolOperation};

struct ProjectInvocation<'a> {
    argv: Vec<String>,
    stdin: Option<&'a [u8]>,
    grep_no_match_is_success: bool,
}

pub(crate) fn tool_name(tool: &ProjectToolOperation) -> &'static str {
    match tool {
        ProjectToolOperation::ReadFile { .. } => "read_file",
        ProjectToolOperation::SearchFiles { .. } => "search_files",
        ProjectToolOperation::WriteFile { .. } => "write_file",
        ProjectToolOperation::DeleteFile { .. } => "delete_file",
        ProjectToolOperation::RunCommand { .. } => "run_command",
        ProjectToolOperation::Git { .. } => "git",
    }
}

fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && !path.starts_with('/')
        // Control characters would let a name smuggle line breaks or escapes into git output and terminal transcripts.
        && !path.chars().any(char::is_control)
        && !path
            .split('/')
            .any(|part| part.eq_ignore_ascii_case(".git"))
        && Path::new(path)
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

fn valid_command(argv: &[String]) -> bool {
    if argv.is_empty()
        || argv.len() > 64
        || argv
            .iter()
            .any(|argument| argument.is_empty() || argument.len() > 4096 || argument.contains('\0'))
    {
        return false;
    }
    matches!(
        argv,
        [program, ..] if program == "cargo"
            && (argv.get(1).is_some_and(|value| value == "test")
                || argv.get(1).is_some_and(|value| value == "fmt")
                    && argv.get(2).is_some_and(|value| value == "--check"))
            || program == "swift" && argv.get(1).is_some_and(|value| value == "test")
            || program == "npm" && argv.get(1).is_some_and(|value| value == "test")
            || program == "python3"
                && argv.get(1).is_some_and(|value| value == "-m")
                && argv.get(2).is_some_and(|value| value == "pytest")
    )
}

pub(crate) fn validate(tool: &ProjectToolOperation) -> Result<(), BackendError> {
    let check_path = |path: &str| {
        valid_path(path)
            .then_some(())
            .ok_or_else(|| BackendError::InvalidInput("project file path is unsafe".into()))
    };
    match tool {
        ProjectToolOperation::ReadFile { path } | ProjectToolOperation::DeleteFile { path } => {
            check_path(path)
        }
        ProjectToolOperation::SearchFiles { path, pattern } => {
            check_path(path)?;
            if pattern.is_empty() || pattern.len() > 4096 || pattern.contains('\0') {
                return Err(BackendError::InvalidInput(
                    "project search input is unsafe".into(),
                ));
            }
            Ok(())
        }
        ProjectToolOperation::WriteFile { path, content } => {
            check_path(path)?;
            if content.expose_secret().len() > crate::protocol::MAX_REQUEST_BYTES / 2 {
                return Err(BackendError::InvalidInput(
                    "project write input is unsafe".into(),
                ));
            }
            Ok(())
        }
        ProjectToolOperation::RunCommand { argv } => valid_command(argv)
            .then_some(())
            .ok_or_else(|| BackendError::InvalidInput("project command is not allowlisted".into())),
        ProjectToolOperation::Git { operation } => match operation {
            ProjectGitOperation::Status
            | ProjectGitOperation::Diff
            | ProjectGitOperation::DiffStat => Ok(()),
            ProjectGitOperation::Log { count } if (1..=100).contains(count) => Ok(()),
            ProjectGitOperation::Add { path } => check_path(path),
            ProjectGitOperation::Commit { message }
                if !message.trim().is_empty()
                    && message.len() <= 4000
                    && !message.contains('\0') =>
            {
                Ok(())
            }
            _ => Err(BackendError::InvalidInput(
                "git operation is invalid".into(),
            )),
        },
    }
}

/// Match the container's project label to the requesting project for both tool and terminal access.
pub(crate) fn validate_container(
    docker_bin: &str,
    plan_only: bool,
    container_id: &str,
    project_id: &uuid::Uuid,
) -> Result<(), BackendError> {
    if !crate::protocol::valid_project_container_id(container_id) {
        return Err(BackendError::InvalidInput(
            "project tools require a spark-project-<uuid> container".into(),
        ));
    }
    if plan_only {
        return Ok(());
    }
    let output = Command::new(docker_bin)
        .args([
            "inspect",
            "--format={{index .Config.Labels \"spark.project_id\"}}",
            container_id,
        ])
        .output()?;
    if !output.status.success()
        || String::from_utf8_lossy(&output.stdout).trim() != project_id.to_string()
    {
        return Err(BackendError::InvalidInput(
            "project container does not belong to the requested project".into(),
        ));
    }
    Ok(())
}

fn run(
    docker_bin: &str,
    container_id: &str,
    argv: &[String],
    stdin: Option<&[u8]>,
) -> Result<std::process::Output, BackendError> {
    if argv.is_empty() {
        return Err(BackendError::InvalidInput(
            "project tool argv must not be empty".into(),
        ));
    }
    let mut command = Command::new(docker_bin);
    command
        .args(["exec", "--workdir=/workspace"])
        .args([
            "--env=GIT_CONFIG_NOSYSTEM=1",
            "--env=GIT_CONFIG_GLOBAL=/dev/null",
        ])
        .args(["--env=GIT_EXTERNAL_DIFF=", "--env=GIT_ASKPASS="])
        .args(["--env=GIT_TERMINAL_PROMPT=0"]);
    if stdin.is_some() {
        command.arg("--interactive");
    }
    command.arg(container_id).args(argv);
    command
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    if let Some(bytes) = stdin {
        child
            .stdin
            .take()
            .ok_or_else(|| BackendError::Failure("project tool stdin unavailable".into()))?
            .write_all(bytes)?;
    }
    child.wait_with_output().map_err(BackendError::Io)
}

fn response(
    request_id: uuid::Uuid,
    project_id: &uuid::Uuid,
    container_id: &str,
    tool: &ProjectToolOperation,
    output: std::process::Output,
    grep_no_match_is_success: bool,
) -> Result<PrivilegedResponse, BackendError> {
    let exit_code = output.status.code().unwrap_or(255).clamp(0, 255);
    let ok = output.status.success() || grep_no_match_is_success && exit_code == 1;
    let mut bytes = output.stdout;
    if !ok {
        bytes.extend_from_slice(&output.stderr);
    }
    bytes.truncate(crate::protocol::MAX_RESPONSE_BYTES / 2);
    let text = String::from_utf8(bytes)
        .map_err(|_| BackendError::Failure("project tool returned non-UTF-8 output".into()))?;
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "project_tool_complete".into(),
        message: "project tool completed inside the container".into(),
        details: serde_json::json!({
            "project_id": project_id,
            "container_id": container_id,
            "tool": tool_name(tool),
            "ok": ok,
            "exit_code": exit_code,
            "output": if grep_no_match_is_success && exit_code == 1 && text.is_empty() {
                "no matches"
            } else {
                text.as_str()
            },
        }),
    })
}

pub(crate) fn execute(
    docker_bin: &str,
    plan_only: bool,
    request_id: uuid::Uuid,
    project_id: &uuid::Uuid,
    container_id: &str,
    tool: &ProjectToolOperation,
) -> Result<PrivilegedResponse, BackendError> {
    validate_container(docker_bin, plan_only, container_id, project_id)?;
    validate(tool)?;
    if plan_only {
        return Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned_project_tool".into(),
            message: "project tool plan approved".into(),
            details: serde_json::json!({
                "project_id": project_id,
                "container_id": container_id,
                "tool": tool_name(tool),
                "runs_on_host": false,
            }),
        });
    }

    let invocation = invocation(tool);
    if let ProjectToolOperation::WriteFile { path, .. } = tool
        && let Some(parent) = Path::new(path)
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
    {
        let mkdir = vec![
            "mkdir".into(),
            "-p".into(),
            "--".into(),
            format!("/workspace/{}", parent.display()),
        ];
        if !run(docker_bin, container_id, &mkdir, None)?
            .status
            .success()
        {
            return Err(BackendError::Failure(
                "project directory could not be created".into(),
            ));
        }
    }
    let output = run(docker_bin, container_id, &invocation.argv, invocation.stdin)?;
    let result = response(
        request_id,
        project_id,
        container_id,
        tool,
        output,
        invocation.grep_no_match_is_success,
    )?;
    verify_git_add(docker_bin, container_id, tool, &result)?;
    Ok(result)
}

fn invocation(tool: &ProjectToolOperation) -> ProjectInvocation<'_> {
    match tool {
        ProjectToolOperation::ReadFile { path } => ProjectInvocation {
            argv: vec!["cat".into(), "--".into(), format!("/workspace/{path}")],
            stdin: None,
            grep_no_match_is_success: false,
        },
        ProjectToolOperation::SearchFiles { path, pattern } => ProjectInvocation {
            argv: vec![
                "grep".into(),
                "-RFn".into(),
                "--exclude-dir=.git".into(),
                "--".into(),
                pattern.clone(),
                format!("/workspace/{path}"),
            ],
            stdin: None,
            grep_no_match_is_success: true,
        },
        ProjectToolOperation::WriteFile { path, content } => ProjectInvocation {
            argv: vec![
                "dd".into(),
                format!("of=/workspace/{path}"),
                "status=none".into(),
                "conv=fsync".into(),
            ],
            stdin: Some(content.expose_secret().as_bytes()),
            grep_no_match_is_success: false,
        },
        ProjectToolOperation::DeleteFile { path } => ProjectInvocation {
            argv: vec!["rm".into(), "--".into(), format!("/workspace/{path}")],
            stdin: None,
            grep_no_match_is_success: false,
        },
        ProjectToolOperation::RunCommand { argv } => ProjectInvocation {
            argv: argv.clone(),
            stdin: None,
            grep_no_match_is_success: false,
        },
        ProjectToolOperation::Git { operation } => ProjectInvocation {
            argv: git_argv(operation),
            stdin: None,
            grep_no_match_is_success: false,
        },
    }
}

fn git_argv(operation: &ProjectGitOperation) -> Vec<String> {
    let mut argv = vec![
        "git".into(),
        "-c".into(),
        "protocol.allow=never".into(),
        "-c".into(),
        "core.fsmonitor=false".into(),
        "-c".into(),
        "core.hooksPath=/dev/null".into(),
        "-c".into(),
        "commit.gpgSign=false".into(),
        "-c".into(),
        "user.name=Spark Agent".into(),
        "-c".into(),
        "user.email=agent@spark.invalid".into(),
    ];
    match operation {
        ProjectGitOperation::Status => argv.extend([
            "status".into(),
            "--porcelain=v1".into(),
            "--untracked-files=all".into(),
        ]),
        ProjectGitOperation::Diff => argv.extend(["diff".into(), "--no-ext-diff".into()]),
        ProjectGitOperation::DiffStat => argv.extend([
            "diff".into(),
            "--no-ext-diff".into(),
            "--stat".into(),
            "HEAD".into(),
        ]),
        ProjectGitOperation::Log { count } => argv.extend([
            "log".into(),
            "--oneline".into(),
            "-n".into(),
            count.to_string(),
        ]),
        ProjectGitOperation::Add { path } => argv.extend(["add".into(), "--".into(), path.clone()]),
        ProjectGitOperation::Commit { message } => argv.extend([
            "commit".into(),
            "--quiet".into(),
            "-m".into(),
            message.clone(),
        ]),
    }
    argv
}

fn verify_git_add(
    docker_bin: &str,
    container_id: &str,
    tool: &ProjectToolOperation,
    result: &PrivilegedResponse,
) -> Result<(), BackendError> {
    let ProjectToolOperation::Git {
        operation: ProjectGitOperation::Add { path },
    } = tool
    else {
        return Ok(());
    };
    if !result
        .details
        .get("ok")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(());
    }
    let verify = vec![
        "git".into(),
        "diff".into(),
        "--cached".into(),
        "--name-only".into(),
        "-z".into(),
        "--".into(),
        path.clone(),
    ];
    let verified = run(docker_bin, container_id, &verify, None)?;
    if !verified.status.success() {
        return Err(BackendError::Failure(
            "git add result could not be verified".into(),
        ));
    }
    let staged = String::from_utf8(verified.stdout)
        .map_err(|_| BackendError::Failure("git add returned a non-UTF-8 path".into()))?;
    let paths = staged
        .split('\0')
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    if paths.is_empty()
        || paths.iter().any(|staged_path| {
            !valid_path(staged_path)
                || (*staged_path != path && !staged_path.starts_with(&format!("{path}/")))
        })
    {
        return Err(BackendError::Failure(
            "git add did not stage the requested path".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod control_data_tests {
    use super::*;

    #[test]
    fn file_tools_cannot_address_git_control_data() {
        for path in [".git/config", "nested/.git/HEAD", ".GIT/refs/heads/main"] {
            assert!(!valid_path(path));
        }
        assert!(valid_path("src/git.rs"));
    }

    #[test]
    fn file_tools_refuse_control_characters_in_paths() {
        for path in [
            "src/\x01evil.rs",
            "src/a\tb.rs",
            "src/a\nb.rs",
            "src/a\rb.rs",
            "src/\x1b[31mred.rs",
            "src/a\x7fb.rs",
            "src/a\0b.rs",
        ] {
            assert!(!valid_path(path), "accepted {path:?}");
        }
        assert!(valid_path("src/spaces and unicode-\u{e9}.rs"));
    }
}

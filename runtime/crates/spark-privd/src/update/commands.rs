use super::*;

/// Cap on captured subprocess output so a noisy child cannot exhaust memory.
pub const MAX_COMMAND_OUTPUT_BYTES: usize = 1 << 20;

/// One captured subprocess run. Output is bounded by the runner.
#[derive(Debug, Clone, Default)]
pub struct CommandOutput {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl CommandOutput {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }
    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}

/// Execute fixed arguments through a replaceable boundary for deterministic failure tests.
pub trait CommandRunner: Send + Sync {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutput, String>;

    /// Send secrets only through stdin, excluding them from arguments, logs, recorded calls and errors.
    fn run_with_secret_input(
        &self,
        program: &str,
        args: &[String],
        secret: &str,
    ) -> Result<CommandOutput, String>;
}

/// Real runner: `std::process::Command`, never a shell.
#[derive(Debug, Default)]
pub struct SystemCommandRunner;

impl CommandRunner for SystemCommandRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutput, String> {
        let output = std::process::Command::new(program)
            .args(args)
            .output()
            .map_err(|error| format!("failed to execute {program}: {error}"))?;
        let cap = |bytes: Vec<u8>| -> Vec<u8> {
            bytes.into_iter().take(MAX_COMMAND_OUTPUT_BYTES).collect()
        };
        Ok(CommandOutput {
            status: output.status.code(),
            stdout: cap(output.stdout),
            stderr: cap(output.stderr),
        })
    }

    fn run_with_secret_input(
        &self,
        program: &str,
        args: &[String],
        secret: &str,
    ) -> Result<CommandOutput, String> {
        use std::process::{Command, Stdio};

        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("failed to execute {program}: {error}"))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| format!("failed to open {program} stdin"))?;
        stdin
            .write_all(secret.as_bytes())
            .and_then(|_| stdin.write_all(b"\n"))
            .map_err(|error| format!("failed to provide input to {program}: {error}"))?;
        drop(stdin);
        let output = child
            .wait_with_output()
            .map_err(|error| format!("failed to wait for {program}: {error}"))?;
        let cap = |bytes: Vec<u8>| -> Vec<u8> {
            bytes.into_iter().take(MAX_COMMAND_OUTPUT_BYTES).collect()
        };
        Ok(CommandOutput {
            status: output.status.code(),
            stdout: cap(output.stdout),
            stderr: cap(output.stderr),
        })
    }
}

/// Record argument vectors and return scripted results in order.
#[derive(Debug, Default)]
pub struct RecordingRunner {
    pub calls: Mutex<Vec<(String, Vec<String>)>>,
    pub results: Mutex<std::collections::VecDeque<Result<CommandOutput, String>>>,
}

impl RecordingRunner {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn push(&self, result: Result<CommandOutput, String>) {
        self.results.lock().push_back(result);
    }
    pub fn ok(&self, status: Option<i32>, stdout: &str, stderr: &str) {
        self.push(Ok(CommandOutput {
            status,
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        }));
    }
    pub fn calls(&self) -> Vec<(String, Vec<String>)> {
        self.calls.lock().clone()
    }
    pub fn argv_of(&self, program: &str) -> Vec<Vec<String>> {
        self.calls()
            .into_iter()
            .filter(|(program_name, _)| program_name == program)
            .map(|(_, args)| args)
            .collect()
    }
}

impl CommandRunner for RecordingRunner {
    fn run(&self, program: &str, args: &[String]) -> Result<CommandOutput, String> {
        self.calls.lock().push((program.to_owned(), args.to_vec()));
        self.results
            .lock()
            .pop_front()
            .unwrap_or_else(|| Ok(CommandOutput::default()))
    }

    fn run_with_secret_input(
        &self,
        program: &str,
        args: &[String],
        _secret: &str,
    ) -> Result<CommandOutput, String> {
        self.run(program, args)
    }
}

/// Ignore zombies during quiescence checks because exited processes hold no descriptors that can race an update.
pub(super) fn is_zombie(proc_dir: &Path) -> bool {
    let Ok(stat) = fs::read_to_string(proc_dir.join("stat")) else {
        return false;
    };
    // Parse state after the last closing parenthesis because executable names may contain spaces and parentheses.
    let Some(index) = stat.rfind(')') else {
        return false;
    };
    let tail = &stat[index + 1..];
    tail.split_whitespace().next() == Some("Z")
}

pub(super) fn truncate(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut out = String::new();
    for character in text.chars().take(max) {
        out.push(character);
    }
    out
}

use super::*;

pub(super) fn run(
    plan_only: bool,
    runner: &dyn CommandRunner,
    program: &str,
    args: Vec<String>,
    secret: Option<&str>,
) -> Result<crate::update::CommandOutput, BackendError> {
    if plan_only {
        return Ok(crate::update::CommandOutput {
            status: Some(0),
            stdout: Vec::new(),
            stderr: Vec::new(),
        });
    }
    match secret {
        Some(secret) => runner.run_with_secret_input(program, &args, secret),
        None => runner.run(program, &args),
    }
    .map_err(BackendError::Failure)
}

use super::*;

pub(super) struct ApplianceCommands<'a> {
    pub(super) plan_only: bool,
    pub(super) appliance_command_runner: &'a dyn CommandRunner,
}

impl ApplianceCommands<'_> {
    pub(super) fn run_appliance(
        &self,
        program: &str,
        args: Vec<String>,
        secret: Option<&str>,
    ) -> Result<crate::update::CommandOutput, BackendError> {
        command::run(
            self.plan_only,
            self.appliance_command_runner,
            program,
            args,
            secret,
        )
    }

    pub(super) fn appliance_plan(
        &self,
        request_id: uuid::Uuid,
        message: &str,
        program: &str,
        args: &[String],
        secret_stdin: bool,
    ) -> Option<PrivilegedResponse> {
        self.plan_only.then(|| PrivilegedResponse {
            request_id,
            accepted: true,
            code: "planned".into(),
            message: message.into(),
            details: serde_json::json!({
                "program": program,
                "args": args,
                "secret_stdin": secret_stdin,
            }),
        })
    }
}

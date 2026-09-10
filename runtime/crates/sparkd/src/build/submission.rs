use super::*;

pub(super) struct Submission<'a> {
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) jobs: &'a JobService,
}

impl Submission<'_> {
    /// Validate + queue a build job against an immutable commit.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_build(
        &self,
        operation_id: Uuid,
        project: &ProjectView,
        commit: &str,
        source_sha256: &str,
        scheme: &str,
        configuration: &str,
        destination: &str,
        actions: Vec<String>,
        timeout_seconds: i64,
        requirements: &BuildRequirements,
        requested_by: &Uuid,
    ) -> Result<Uuid, String> {
        let mut conn = self.db.lock();
        let transaction = conn.transaction().map_err(|error| error.to_string())?;
        let build_id = self.submit_build_in(
            &transaction,
            operation_id,
            project,
            commit,
            source_sha256,
            scheme,
            configuration,
            destination,
            actions,
            timeout_seconds,
            requirements,
            requested_by,
        )?;
        transaction.commit().map_err(|error| error.to_string())?;
        Ok(build_id)
    }

    /// Commit the replay record, operation and build input atomically in the caller transaction.
    #[allow(clippy::too_many_arguments)]
    pub fn submit_build_in(
        &self,
        conn: &rusqlite::Connection,
        operation_id: Uuid,
        project: &ProjectView,
        commit: &str,
        source_sha256: &str,
        scheme: &str,
        configuration: &str,
        destination: &str,
        actions: Vec<String>,
        timeout_seconds: i64,
        requirements: &BuildRequirements,
        requested_by: &Uuid,
    ) -> Result<Uuid, String> {
        let stored = store::project_row(conn, &project.id)
            .map_err(|e| e.to_string())?
            .ok_or("PROJECT_NOT_FOUND")?;
        if stored.state == "deleting" {
            return Err("PROJECT_DELETING".into());
        }
        if !is_sha1_immutable(commit) {
            return Err("BUILD_COMMIT_NOT_IMMUTABLE".into());
        }
        if !is_sha256(source_sha256) {
            return Err("BUILD_SOURCE_DIGEST_INVALID".into());
        }
        validate_requirements(requirements)?;
        for (name, value, maximum) in [
            ("scheme", scheme, 200),
            ("configuration", configuration, 100),
            ("destination", destination, 500),
        ] {
            if value.is_empty() || value.len() > maximum || value.chars().any(char::is_control) {
                return Err(format!("{name} out of range"));
            }
        }
        for action in &actions {
            if !matches!(action.as_str(), "build" | "test") {
                return Err(format!("unknown action {action:?}"));
            }
        }
        if actions.is_empty() || actions.len() > 2 {
            return Err("actions out of range".into());
        }
        if !(60..=1800).contains(&timeout_seconds) {
            return Err("timeout_seconds out of range".into());
        }
        let id = Uuid::new_v4();
        let submitted_at = self.jobs.now_rfc3339();
        self.jobs
            .create_with_id(
                conn,
                operation_id,
                "build.submit",
                *requested_by,
                Some(&id.to_string()),
                &serde_json::to_string(&json!({
                    "commit": commit,
                    "source_sha256": source_sha256,
                    "scheme": scheme,
                    "actions": actions,
                }))
                .unwrap_or_else(|_| "{}".into()),
            )
            .map_err(|e| e.to_string())?;
        let row = store::BuildRow {
            id,
            project_id: project.id,
            operation_id,
            requested_by_device_id: *requested_by,
            worker_id: None,
            commit_sha: commit.to_owned(),
            source_sha256: source_sha256.to_ascii_lowercase(),
            scheme: scheme.to_owned(),
            configuration: configuration.to_owned(),
            destination: destination.to_owned(),
            actions_json: serde_json::to_string(&actions).unwrap_or_else(|_| "[]".into()),
            timeout_seconds,
            status: "queued".into(),
            result_json: "{}".into(),
            created_at: String::new(),
            updated_at: String::new(),
            claim_token_hash: None,
            claim_expires_at: None,
            claim_generation: 0,
            claim_request_id: None,
            requirements_json: serde_json::to_string(requirements).map_err(|e| e.to_string())?,
            recipe_json: None,
            recipe_sha256: None,
            artifact_token_hash: None,
        };
        store::insert_build_at(conn, &row, &submitted_at).map_err(|e| e.to_string())?;
        Ok(id)
    }
}

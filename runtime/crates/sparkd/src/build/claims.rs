use super::*;

use ed25519_dalek::Signer as _;

pub(super) struct Claims<'a> {
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) jobs: &'a JobService,
    pub(super) identity: &'a NodeIdentity,
    pub(super) events: &'a EventBus,
    pub(super) work_dir: &'a Path,
    pub(super) claim_lock: &'a Mutex<()>,
}

impl Claims<'_> {
    pub fn heartbeat(&self, worker_id: &Uuid, device_id: &Uuid) -> Result<usize, String> {
        let _guard = self.claim_lock.lock();
        let now = self.jobs.now_rfc3339();
        let expires = self.deadline(WORKER_LIVENESS_SECONDS)?;
        let conn = self.db.lock();
        self.requeue_expired_locked(&conn)?;
        let worker = store::build_worker_row(&conn, worker_id)
            .map_err(|error| error.to_string())?
            .ok_or("BUILD_WORKER_NOT_FOUND")?;
        if worker.device_id != *device_id || worker.state == "revoked" {
            return Err("BUILD_WORKER_FORBIDDEN".into());
        }
        store::heartbeat_build_worker(&conn, worker_id, &now, &expires)
            .map_err(|error| error.to_string())?;
        store::active_build_count_for_worker(&conn, worker_id).map_err(|error| error.to_string())
    }

    /// Claim the oldest compatible job within the worker project ACL and advertised concurrency.
    pub fn claim_next(
        &self,
        worker_id: &Uuid,
        device_id: &Uuid,
        request_id: &Uuid,
    ) -> Result<Option<BuildClaim>, String> {
        let _guard = self.claim_lock.lock();
        let conn = self.db.lock();
        self.requeue_expired_locked(&conn)?;
        let worker = store::build_worker_row(&conn, worker_id)
            .map_err(|error| error.to_string())?
            .ok_or("BUILD_WORKER_NOT_FOUND")?;
        if worker.device_id != *device_id || worker.state == "revoked" {
            return Err("BUILD_WORKER_FORBIDDEN".into());
        }
        let now = self.jobs.now();
        if worker
            .heartbeat_expires_at
            .as_deref()
            .and_then(parse_time)
            .is_none_or(|deadline| now >= deadline)
        {
            return Err("BUILD_WORKER_OFFLINE".into());
        }
        if let Some(build) =
            store::build_claim_for_request(&conn, worker_id, request_id, &self.jobs.now_rfc3339())
                .map_err(|error| error.to_string())?
        {
            let recipe: SignedBuildRecipe =
                serde_json::from_str(build.recipe_json.as_deref().ok_or("BUILD_RECIPE_INVALID")?)
                    .map_err(|_| "BUILD_RECIPE_INVALID")?;
            let recipe_sha256 = build.recipe_sha256.ok_or("BUILD_RECIPE_INVALID")?;
            let expires_at = build.claim_expires_at.ok_or("BUILD_CLAIM_INVALID")?;
            return Ok(Some(BuildClaim {
                recipe,
                recipe_sha256,
                lease: BuildLease {
                    claim_token: self.claim_secret(
                        "claim",
                        &build.id,
                        worker_id,
                        build.claim_generation,
                        request_id,
                    ),
                    artifact_token: self.claim_secret(
                        "artifact",
                        &build.id,
                        worker_id,
                        build.claim_generation,
                        request_id,
                    ),
                    expires_at,
                    heartbeat_seconds: HEARTBEAT_SECONDS,
                },
            }));
        }
        let capabilities: Value = serde_json::from_str(&worker.capabilities_json)
            .map_err(|_| "BUILD_WORKER_CAPABILITIES_INVALID")?;
        let max_concurrent = capabilities
            .get("max_concurrent_jobs")
            .and_then(Value::as_u64)
            .unwrap_or(1)
            .clamp(1, 8) as usize;
        if store::active_build_count_for_worker(&conn, worker_id)
            .map_err(|error| error.to_string())?
            >= max_concurrent
        {
            return Err("BUILD_WORKER_AT_CAPACITY".into());
        }
        let build = store::build_rows(&conn, 200)
            .map_err(|error| error.to_string())?
            .into_iter()
            .filter(|build| build.status == "queued")
            .find(|build| {
                let member = store::project_permission(&conn, &build.project_id, device_id)
                    .ok()
                    .flatten()
                    .is_some();
                let requirements =
                    serde_json::from_str::<BuildRequirements>(&build.requirements_json).ok();
                member
                    && build.source_sha256
                        != "0000000000000000000000000000000000000000000000000000000000000000"
                    && requirements
                        .as_ref()
                        .is_some_and(|required| worker_matches(&worker, &capabilities, required))
            });
        let Some(build) = build else {
            return Ok(None);
        };
        let project = store::project_row(&conn, &build.project_id)
            .map_err(|error| error.to_string())?
            .ok_or("PROJECT_NOT_FOUND")?;
        let issued_at = self.jobs.now_rfc3339();
        let lease_expires_at = self.deadline(CLAIM_LEASE_SECONDS)?;
        let recipe_expires_at = self.deadline(build.timeout_seconds.saturating_add(600))?;
        let claim_generation = build.claim_generation.saturating_add(1);
        let claim_token =
            self.claim_secret("claim", &build.id, worker_id, claim_generation, request_id);
        let artifact_token = self.claim_secret(
            "artifact",
            &build.id,
            worker_id,
            claim_generation,
            request_id,
        );
        let requirements = serde_json::from_str(&build.requirements_json)
            .map_err(|_| "BUILD_REQUIREMENTS_INVALID")?;
        let source_ticket = BuildSourceTicket {
            ticket_id: Uuid::new_v4(),
            repository_url: project.repository_url,
            commit: build.commit_sha.clone(),
            source_sha256: build.source_sha256.clone(),
            max_bytes: SOURCE_LIMIT_BYTES,
            expires_at: recipe_expires_at.clone(),
        };
        let artifact_ticket = BuildArtifactTicket {
            ticket_id: Uuid::new_v4(),
            upload_path_template: format!("/api/v1/builds/{}/artifacts/{{artifactId}}", build.id),
            max_file_bytes: MAX_ARTIFACT_BYTES,
            max_total_bytes: MAX_ARTIFACT_TOTAL_BYTES,
            max_files: MAX_ARTIFACTS,
            expires_at: recipe_expires_at.clone(),
        };
        let payload = BuildRecipePayload {
            protocol: PROTOCOL_VERSION.into(),
            build_id: build.id,
            worker_id: *worker_id,
            claim_generation,
            project_id: build.project_id,
            commit: build.commit_sha.clone(),
            source_sha256: build.source_sha256.clone(),
            scheme: build.scheme.clone(),
            configuration: build.configuration.clone(),
            destination: build.destination.clone(),
            actions: serde_json::from_str(&build.actions_json)
                .map_err(|_| "BUILD_ACTIONS_INVALID")?,
            timeout_seconds: build.timeout_seconds,
            requirements,
            source_ticket,
            artifact_ticket,
            issued_at,
            expires_at: recipe_expires_at,
        };
        let recipe = SignedBuildRecipe::issue(self.identity, payload)?;
        let recipe_sha256 = recipe.digest()?;
        let recipe_json = serde_json::to_string(&recipe).map_err(|error| error.to_string())?;
        let transaction = conn
            .unchecked_transaction()
            .map_err(|error| error.to_string())?;
        let changed = store::claim_build(
            &transaction,
            &build.id,
            worker_id,
            &crate::crypto::sha256_hex(claim_token.as_bytes()).into_bytes(),
            &crate::crypto::sha256_hex(artifact_token.as_bytes()).into_bytes(),
            request_id,
            &lease_expires_at,
            &recipe_json,
            &recipe_sha256,
            &self.jobs.now_rfc3339(),
        )
        .map_err(|error| error.to_string())?;
        if !changed {
            return Ok(None);
        }
        store::update_build_worker_state_at(
            &transaction,
            worker_id,
            "busy",
            &self.jobs.now_rfc3339(),
        )
        .map_err(|error| error.to_string())?;
        transaction.commit().map_err(|error| error.to_string())?;
        self.announce(
            Some(&conn),
            Some(build.operation_id),
            "build.started",
            "info",
            json!({
                "build_id": build.id,
                "worker_id": worker_id,
                "project_id": build.project_id,
                "claim_generation": claim_generation,
            }),
            crate::events::Visibility::project(build.project_id),
        );
        Ok(Some(BuildClaim {
            recipe,
            recipe_sha256,
            lease: BuildLease {
                claim_token,
                artifact_token,
                expires_at: lease_expires_at,
                heartbeat_seconds: HEARTBEAT_SECONDS,
            },
        }))
    }

    /// Verify an unexpired build claim by constant-time comparison of its token digest.
    pub fn verify_claim(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        presented: &str,
    ) -> Result<store::BuildRow, &'static str> {
        let conn = self.db.lock();
        self.verify_claim_locked(&conn, build_id, worker_id, presented)
    }

    pub(super) fn verify_claim_locked(
        &self,
        conn: &rusqlite::Connection,
        build_id: &Uuid,
        worker_id: &Uuid,
        presented: &str,
    ) -> Result<store::BuildRow, &'static str> {
        let build = store::build_row(conn, build_id)
            .map_err(|_| "BUILD_NOT_FOUND")?
            .ok_or("BUILD_NOT_FOUND")?;
        if build.worker_id != Some(*worker_id)
            || !matches!(build.status.as_str(), "claimed" | "running")
        {
            return Err("BUILD_CLAIM_INVALID");
        }
        let (Some(stored), Some(expires_at)) = (
            build.claim_token_hash.as_ref(),
            build.claim_expires_at.as_ref(),
        ) else {
            return Err("BUILD_NOT_CLAIMED");
        };
        let now = self.jobs.now();
        let expires =
            time::OffsetDateTime::parse(expires_at, &Rfc3339).map_err(|_| "BUILD_CLAIM_INVALID")?;
        if now >= expires {
            return Err("BUILD_CLAIM_EXPIRED");
        }
        let presented_hash = crate::crypto::sha256_hex(presented.as_bytes()).into_bytes();
        if !constant_time_eq(stored, &presented_hash) {
            return Err("BUILD_CLAIM_INVALID");
        }
        Ok(build)
    }

    pub fn renew_claim(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
    ) -> Result<(String, bool), &'static str> {
        let conn = self.db.lock();
        let build = self.verify_claim_locked(&conn, build_id, worker_id, claim_token)?;
        let operation = self
            .jobs
            .get(&conn, build.operation_id)
            .map_err(|_| "BUILD_OPERATION_INVALID")?
            .ok_or("BUILD_OPERATION_INVALID")?;
        let cancel_requested = operation.state == "cancelling";
        let expires_at = self
            .deadline(CLAIM_LEASE_SECONDS)
            .map_err(|_| "BUILD_LEASE_RENEW_FAILED")?;
        let changed = store::renew_build_claim(
            &conn,
            build_id,
            worker_id,
            build
                .claim_token_hash
                .as_deref()
                .ok_or("BUILD_CLAIM_INVALID")?,
            build.claim_generation,
            &self.jobs.now_rfc3339(),
            &expires_at,
            &self.jobs.now_rfc3339(),
        )
        .map_err(|_| "BUILD_LEASE_RENEW_FAILED")?;
        if !changed {
            return Err("BUILD_CLAIM_LOST");
        }
        Ok((expires_at, cancel_requested))
    }

    pub fn requeue_expired(&self) -> Result<usize, String> {
        let _guard = self.claim_lock.lock();
        let conn = self.db.lock();
        self.requeue_expired_locked(&conn)
    }

    fn requeue_expired_locked(&self, conn: &rusqlite::Connection) -> Result<usize, String> {
        let now = self.jobs.now_rfc3339();
        let expired = store::expired_build_claims(conn, &now).map_err(|e| e.to_string())?;
        let mut transitioned_count = 0;
        for build in &expired {
            let transaction = conn.unchecked_transaction().map_err(|e| e.to_string())?;
            let operation = self
                .jobs
                .get(&transaction, build.operation_id)
                .map_err(|error| error.to_string())?;
            let cancelled = operation
                .as_ref()
                .is_some_and(|operation| operation.state == "cancelling");
            let transitioned = if cancelled {
                store::cancel_expired_build(&transaction, &build.id, build.claim_generation, &now)
                    .map_err(|e| e.to_string())?
            } else {
                store::requeue_expired_build(&transaction, &build.id, build.claim_generation, &now)
                    .map_err(|e| e.to_string())?
            };
            if !transitioned {
                continue;
            }
            if cancelled {
                self.jobs
                    .cancelled(&transaction, build.operation_id, "OPERATION_CANCELLED")
                    .map_err(|e| e.to_string())?;
            }
            let generation_dir = self
                .work_dir
                .join("builds")
                .join(build.id.to_string())
                .join(build.claim_generation.to_string());
            if generation_dir.exists() {
                std::fs::remove_dir_all(generation_dir).map_err(|e| e.to_string())?;
            }
            if let Some(worker_id) = build.worker_id
                && store::active_build_count_for_worker(&transaction, &worker_id)
                    .map_err(|e| e.to_string())?
                    == 0
            {
                store::update_build_worker_state_at(&transaction, &worker_id, "online", &now)
                    .map_err(|e| e.to_string())?;
            }
            transaction.commit().map_err(|e| e.to_string())?;
            transitioned_count += 1;
        }
        self.retire_silent_workers(conn)?;
        Ok(transitioned_count)
    }

    /// PLAN 60.2: persist and announce the offline transition once, rather than only projecting it on read.
    fn retire_silent_workers(&self, conn: &rusqlite::Connection) -> Result<(), String> {
        let now = self.jobs.now();
        for worker in store::build_worker_rows(conn).map_err(|e| e.to_string())? {
            let lapsed = worker
                .heartbeat_expires_at
                .as_deref()
                .and_then(parse_time)
                .is_none_or(|deadline| now >= deadline);
            if !lapsed || matches!(worker.state.as_str(), "revoked" | "offline") {
                continue;
            }
            store::update_build_worker_state_at(
                conn,
                &worker.id,
                "offline",
                &self.jobs.now_rfc3339(),
            )
            .map_err(|e| e.to_string())?;
            self.announce(
                Some(conn),
                None,
                "build.worker.offline",
                "warning",
                json!({ "worker_id": worker.id, "display_name": worker.display_name }),
                crate::events::Visibility::min_role(crate::capability::Role::User),
            );
        }
        Ok(())
    }

    pub(super) fn announce(
        &self,
        conn: Option<&rusqlite::Connection>,
        operation_id: Option<Uuid>,
        event_type: &str,
        severity: &str,
        payload: Value,
        visibility: crate::events::Visibility,
    ) {
        self.events.emit_scoped(
            conn,
            &self.identity.node_id().to_string(),
            operation_id,
            event_type,
            severity,
            payload,
            visibility,
        );
    }

    pub(super) fn deadline(&self, seconds: i64) -> Result<String, String> {
        self.jobs
            .now()
            .saturating_add(time::Duration::seconds(seconds))
            .format(&Rfc3339)
            .map_err(|error| error.to_string())
    }

    fn claim_secret(
        &self,
        purpose: &str,
        build_id: &Uuid,
        worker_id: &Uuid,
        generation: i64,
        request_id: &Uuid,
    ) -> String {
        let material = format!(
            "spark-build-claim-v1\0{purpose}\0{build_id}\0{worker_id}\0{generation}\0{request_id}"
        );
        let signature = self.identity.signing_key().sign(material.as_bytes());
        crate::crypto::base64url_encode(&signature.to_bytes()[..32])
    }
}

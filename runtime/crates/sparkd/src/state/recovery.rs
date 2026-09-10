//! Resume the durable work a previous process abandoned, before this one accepts mutations.

use uuid::Uuid;

use super::AppState;

impl AppState {
    /// A resume that could not start settles the operation, unless a worker already holds it.
    fn abandon(&self, operation_id: Uuid, report: &mut crate::jobs::RecoveryReport) {
        let Some(database) = &self.database else {
            return;
        };
        let conn = database.lock();
        if self.jobs.is_leased(&conn, operation_id) {
            // A worker took it between the scan and the spawn; it is already being handled.
            return;
        }
        if let Err(error) = self.jobs.fail(
            &conn,
            operation_id,
            "OPERATION_RECOVERY_SERVICE_UNAVAILABLE",
        ) {
            tracing::warn!(%error, %operation_id, "an unresumable operation could not be settled");
            return;
        }
        report.resumable = report.resumable.saturating_sub(1);
        report.failed += 1;
    }

    /// Recover abandoned durable work after service composition and before accepting HTTP mutations.
    pub fn recover_abandoned_operations(
        &self,
    ) -> Result<crate::jobs::RecoveryReport, crate::store::StoreError> {
        let Some(database) = &self.database else {
            return Ok(crate::jobs::RecoveryReport::default());
        };
        let (mut report, actions) = {
            let mut conn = database.lock();
            self.jobs.recover_abandoned(&mut conn)?
        };
        for action in actions {
            match action {
                crate::jobs::RecoveryAction::ResumeModelInstall {
                    operation_id,
                    model_id,
                    provider_credential_id,
                } => {
                    if crate::download_api::spawn_install_worker(
                        self,
                        operation_id,
                        &model_id,
                        provider_credential_id,
                    )
                    .is_err()
                    {
                        self.abandon(operation_id, &mut report);
                    }
                }
                crate::jobs::RecoveryAction::ReconcileRuntimeUpdate {
                    operation_id,
                    release_id,
                    system_packages,
                    firmware,
                } => {
                    let Some(privileged) = self.privileged.clone() else {
                        self.abandon(operation_id, &mut report);
                        continue;
                    };
                    if self
                        .jobs
                        .spawn_leased(database.clone(), operation_id, move |lease| {
                            crate::appliance_api::complete_runtime_update(
                                &privileged,
                                &release_id,
                                system_packages,
                                firmware,
                                lease,
                            );
                        })
                        .is_err()
                    {
                        self.abandon(operation_id, &mut report);
                    }
                }
                crate::jobs::RecoveryAction::ResumeCatalogueRefresh {
                    operation_id,
                    candidate_json,
                } => {
                    if crate::catalogue_api::spawn_refresh_worker(
                        self,
                        operation_id,
                        candidate_json,
                    )
                    .is_err()
                    {
                        self.abandon(operation_id, &mut report);
                    }
                }
            }
        }
        Ok(report)
    }
}

//! Durable, digest-bound review decisions and fail-closed merge checks.

use serde_json::json;
use uuid::Uuid;

use crate::agent::AgentService;
use crate::store;

/// The two ways a reviewer can decline a change, and what each one leaves behind.
#[derive(Debug, Clone, Copy)]
struct ReviewOutcome {
    approval_kind: &'static str,
    change_status: &'static str,
    event_type: &'static str,
}

impl ReviewOutcome {
    const REJECTED: Self = Self {
        approval_kind: "change_reject",
        change_status: "rejected",
        event_type: "change.rejected",
    };
    const CHANGES_REQUESTED: Self = Self {
        approval_kind: "change_request_changes",
        change_status: "editing",
        event_type: "change.changes_requested",
    };
}

impl AgentService {
    pub fn approve_change(
        &self,
        project_id: &Uuid,
        change_id: &Uuid,
        decided_by: &Uuid,
        review_digest: &str,
        comment: Option<&str>,
    ) -> Result<(), String> {
        let row = self.change_in_project(project_id, change_id)?;
        if row.status == "merged" && row.review_digest.as_deref() == Some(review_digest) {
            return Ok(());
        }
        if row.status != "review" && row.status != "approved" {
            return Err(format!("CHANGE_NOT_IN_REVIEW:{}", row.status));
        }
        let evidence = self.verify_review(&row, review_digest)?;
        let project = self.projects.get(&row.project_id)?;
        let evidence_record = json!({
            "review_digest": review_digest,
            "review_evidence": evidence,
        });
        let approval_id = {
            let conn = self.projects.db.lock();
            let existing =
                store::approval_for_resource(&conn, "change_merge", &change_id.to_string())
                    .map_err(|error| error.to_string())?;
            let approval_id = if let Some(existing) = existing {
                let existing_digest =
                    serde_json::from_str::<serde_json::Value>(&existing.evidence_json)
                        .ok()
                        .and_then(|value| {
                            value
                                .get("review_digest")
                                .and_then(serde_json::Value::as_str)
                                .map(str::to_owned)
                        });
                if existing_digest.as_deref() != Some(review_digest) {
                    return Err("REVIEW_DIGEST_STALE".into());
                }
                existing.id
            } else {
                store::insert_approval_with_evidence(
                    &conn,
                    &row.operation_id,
                    "change_merge",
                    &change_id.to_string(),
                    Some(decided_by),
                    &evidence_record.to_string(),
                )
                .map_err(|error| error.to_string())?
            };
            store::decide_approval(&conn, &approval_id, "approved", decided_by, comment)
                .map_err(|error| error.to_string())?;
            if row.status == "review"
                && !store::set_change_approved(&conn, change_id)
                    .map_err(|error| error.to_string())?
            {
                return Err("CHANGE_NOT_IN_REVIEW".into());
            }
            approval_id
        };
        let task = row
            .task
            .chars()
            .take(80)
            .map(|character| {
                if character.is_control() {
                    ' '
                } else {
                    character
                }
            })
            .collect::<String>();
        let message = format!("spark: agent change {task}\n\nSpark-Review-Digest: {review_digest}");
        let merged_commit = self.projects.merge_reviewed_worktree(
            &project,
            &crate::project::ReviewedMerge {
                branch: &row.worktree_branch,
                reviewed_head: &evidence.head_commit,
                reviewed_protected_head: &evidence.protected_head_commit,
                review_digest,
                message: &message,
                author: "spark-agent <agent@spark.local>",
            },
        )?;

        let conn = self.projects.db.lock();
        let mut completed_evidence = evidence_record;
        completed_evidence["merged_commit"] = json!(merged_commit);
        store::update_approval_evidence(&conn, &approval_id, &completed_evidence.to_string())
            .map_err(|error| error.to_string())?;
        if !store::set_change_merged(&conn, change_id, &merged_commit)
            .map_err(|error| error.to_string())?
        {
            return Err("CHANGE_MERGE_STATE_LOST".into());
        }
        self.events.emit_scoped(
            Some(&conn),
            &self.node_id,
            Some(row.operation_id),
            "change.merged",
            "info",
            json!({ "change_id": change_id, "decided_by": decided_by }),
            crate::events::Visibility::project(row.project_id),
        );
        Ok(())
    }

    /// Close a change for good: the worktree and its evidence stay, but nothing more happens to it.
    pub fn reject_change(
        &self,
        project_id: &Uuid,
        change_id: &Uuid,
        decided_by: &Uuid,
        review_digest: &str,
        comment: Option<&str>,
    ) -> Result<(), String> {
        self.record_review_decision(
            project_id,
            change_id,
            decided_by,
            review_digest,
            comment,
            ReviewOutcome::REJECTED,
        )
    }

    /// ADR-041 and ADR-014: corrections keep the worktree, diff, tests and tool audit, and put the change back in the agent's hands.
    pub fn request_change_updates(
        &self,
        project_id: &Uuid,
        change_id: &Uuid,
        decided_by: &Uuid,
        review_digest: &str,
        comment: Option<&str>,
    ) -> Result<(), String> {
        self.record_review_decision(
            project_id,
            change_id,
            decided_by,
            review_digest,
            comment,
            ReviewOutcome::CHANGES_REQUESTED,
        )
    }

    fn record_review_decision(
        &self,
        project_id: &Uuid,
        change_id: &Uuid,
        decided_by: &Uuid,
        review_digest: &str,
        comment: Option<&str>,
        outcome: ReviewOutcome,
    ) -> Result<(), String> {
        let conn = self.projects.db.lock();
        let row = store::change_row(&conn, change_id)
            .map_err(|error| error.to_string())?
            .ok_or("CHANGE_NOT_FOUND")?;
        if row.project_id != *project_id {
            return Err("CHANGE_NOT_FOUND".into());
        }
        if row.status != "review" && row.status != "approved" {
            return Err(format!("CHANGE_NOT_IN_REVIEW:{}", row.status));
        }
        self.validate_stored_review(&row, review_digest)?;
        let approval_id = store::insert_approval_with_evidence(
            &conn,
            &row.operation_id,
            outcome.approval_kind,
            &change_id.to_string(),
            Some(decided_by),
            &json!({ "review_digest": review_digest }).to_string(),
        )
        .map_err(|error| error.to_string())?;
        // The approvals table records the two refusals alike; the kind above says which one this was.
        store::decide_approval(&conn, &approval_id, "rejected", decided_by, comment)
            .map_err(|error| error.to_string())?;
        store::update_change_status(&conn, change_id, outcome.change_status)
            .map_err(|error| error.to_string())?;
        self.events.emit_scoped(
            Some(&conn),
            &self.node_id,
            Some(row.operation_id),
            outcome.event_type,
            "warning",
            json!({ "change_id": change_id, "decided_by": decided_by }),
            crate::events::Visibility::project(row.project_id),
        );
        Ok(())
    }

    fn validate_stored_review(
        &self,
        row: &store::ChangeRow,
        review_digest: &str,
    ) -> Result<crate::change_evidence::ReviewEvidence, String> {
        if row.review_digest.as_deref() != Some(review_digest)
            || review_digest.len() != 64
            || !review_digest
                .chars()
                .all(|character| character.is_ascii_hexdigit())
        {
            return Err("REVIEW_DIGEST_STALE".into());
        }
        let evidence: crate::change_evidence::ReviewEvidence =
            serde_json::from_str(&row.review_evidence_json)
                .map_err(|_| "REVIEW_EVIDENCE_INVALID")?;
        evidence.validate_complete()?;
        if evidence.digest()? != review_digest
            || row.base_commit != evidence.base_commit
            || row.head_commit.as_deref() != Some(evidence.head_commit.as_str())
            || row.protected_head_commit.as_deref() != Some(evidence.protected_head_commit.as_str())
        {
            return Err("REVIEW_EVIDENCE_STALE".into());
        }
        Ok(evidence)
    }

    fn verify_review(
        &self,
        row: &store::ChangeRow,
        review_digest: &str,
    ) -> Result<crate::change_evidence::ReviewEvidence, String> {
        let evidence = self.validate_stored_review(row, review_digest)?;
        let worktree = self
            .projects
            .worktree_path_for_branch(&row.worktree_branch)?;
        evidence.verify_checkout(&self.projects, &worktree)?;
        Ok(evidence)
    }
}

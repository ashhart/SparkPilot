use super::*;

pub(super) struct TransactionRecovery<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) link: &'a dyn ClusterLinkControl,
    pub(super) launch_control: launch_control::LaunchControl<'a>,
}

impl TransactionRecovery<'_> {
    pub(super) fn rollback(&self, proposal: &ClusterProposal) -> Result<(), CoordinationError> {
        let row: Option<(String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT proposal_digest,state FROM cluster_transactions WHERE transaction_id=?1 AND cluster_id=?2",
                rusqlite::params![
                    proposal.transaction_id.to_string(),
                    proposal.cluster_id.to_string()
                ],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((digest, state)) = row else {
            return Ok(());
        };
        if digest != proposal.digest()? {
            return Err(CoordinationError::Conflict(
                "rollback proposal digest changed".into(),
            ));
        }
        if state == "rolled_back" {
            return Ok(());
        }
        self.database.lock().execute(
            "UPDATE cluster_transactions SET state='rolling_back',updated_at=?1
             WHERE transaction_id=?2 AND state!='rolled_back'",
            rusqlite::params![
                crate::store::now_iso8601(),
                proposal.transaction_id.to_string()
            ],
        )?;
        let has_membership: bool = self.database.lock().query_row(
            "SELECT EXISTS(SELECT 1 FROM cluster_state WHERE id=?1)",
            [proposal.cluster_id.to_string()],
            |row| row.get(0),
        )?;
        if has_membership {
            self.launch_control.stop_cluster_launches(
                proposal.cluster_id,
                "ROLLBACK_STOP_UNPROVEN",
                "CLUSTER_ROLLED_BACK",
                "failed",
            )?;
        }
        self.link.apply(
            proposal,
            self.identity.node_id(),
            ClusterLinkPhase::Rollback,
        )?;
        let mut conn = self.database.lock();
        let tx = conn.transaction()?;
        if has_membership {
            tx.execute(
                "DELETE FROM cluster_commit_receipts WHERE cluster_id=?1",
                [proposal.cluster_id.to_string()],
            )?;
            tx.execute(
                "DELETE FROM cluster_collective_proofs WHERE cluster_id=?1",
                [proposal.cluster_id.to_string()],
            )?;
            tx.execute(
                "DELETE FROM cluster_link_proofs WHERE cluster_id=?1",
                [proposal.cluster_id.to_string()],
            )?;
            tx.execute(
                "DELETE FROM cluster_device_grants WHERE cluster_id=?1",
                [proposal.cluster_id.to_string()],
            )?;
            tx.execute(
                "DELETE FROM cluster_members WHERE cluster_id=?1",
                [proposal.cluster_id.to_string()],
            )?;
            tx.execute(
                "DELETE FROM cluster_state WHERE id=?1",
                [proposal.cluster_id.to_string()],
            )?;
        }
        tx.execute(
            "UPDATE cluster_transactions SET state='rolled_back',updated_at=?1 WHERE transaction_id=?2",
            rusqlite::params![crate::store::now_iso8601(), proposal.transaction_id.to_string()],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub(super) fn reconcile_expired_transactions_once(
        &self,
        now: OffsetDateTime,
    ) -> Result<usize, CoordinationError> {
        let proposals = {
            let connection = self.database.lock();
            let mut statement = connection.prepare(
                "SELECT proposal_json FROM cluster_transactions
                 WHERE state NOT IN ('ready','rolled_back')",
            )?;
            statement
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let mut recovered = 0;
        for proposal_json in proposals {
            let proposal: ClusterProposal = serde_json::from_str(&proposal_json)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let expires = OffsetDateTime::parse(
                &proposal.expires_at,
                &time::format_description::well_known::Rfc3339,
            )
            .map_err(|_| CoordinationError::Storage("stored proposal expiry is invalid".into()))?;
            if expires <= now {
                self.rollback(&proposal)?;
                recovered += 1;
            }
        }
        Ok(recovered)
    }
}

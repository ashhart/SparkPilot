use super::*;

pub(super) struct TransactionRepository<'a> {
    pub(super) database: &'a Mutex<Connection>,
}

impl TransactionRepository<'_> {
    pub(super) fn retained_grants(&self) -> Result<Vec<ClusterDeviceGrant>, CoordinationError> {
        let connection = self.database.lock();
        let mut statement = connection.prepare(
            "SELECT g.transaction_id,g.cluster_id,g.proposal_digest,g.member_node_id,
                    g.device_id,g.role,g.device_key_fingerprint,g.issued_at,g.expires_at,
                    g.authority_signature
             FROM cluster_device_grants g
             JOIN cluster_state c ON c.id=g.cluster_id
             ORDER BY g.member_node_id",
        )?;
        statement
            .query_map([], |row| {
                Ok(ClusterDeviceGrant {
                    version: PROPOSAL_VERSION,
                    transaction_id: parse_uuid_column(row.get::<_, String>(0)?)?,
                    cluster_id: parse_uuid_column(row.get::<_, String>(1)?)?,
                    proposal_digest: row.get(2)?,
                    member_node_id: parse_uuid_column(row.get::<_, String>(3)?)?,
                    owner_device_id: parse_uuid_column(row.get::<_, String>(4)?)?,
                    role: row.get(5)?,
                    device_key_fingerprint: row.get(6)?,
                    issued_at: row.get(7)?,
                    expires_at: row.get(8)?,
                    authority_signature: row.get(9)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()
            .map_err(Into::into)
    }

    pub(super) fn transaction_state(
        &self,
        proposal: &ClusterProposal,
    ) -> Result<String, CoordinationError> {
        let row: Option<(String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT proposal_digest,state FROM cluster_transactions
                 WHERE transaction_id=?1 AND cluster_id=?2",
                rusqlite::params![
                    proposal.transaction_id.to_string(),
                    proposal.cluster_id.to_string()
                ],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((digest, state)) = row else {
            return Err(CoordinationError::Conflict(
                "transaction was not prepared".into(),
            ));
        };
        if digest != proposal.digest()? {
            return Err(CoordinationError::Conflict(
                "transaction proposal digest changed".into(),
            ));
        }
        Ok(state)
    }

    pub(super) fn existing_transaction(
        &self,
        transaction_id: Uuid,
    ) -> Result<Option<(String, String, String)>, CoordinationError> {
        self
            .database
            .lock()
            .query_row(
                "SELECT proposal_digest,state,grant_json FROM cluster_transactions WHERE transaction_id=?1",
                [transaction_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(Into::into)
    }

    pub(super) fn commit_receipt(
        &self,
        transaction_id: Uuid,
    ) -> Result<ClusterCommitReceipt, CoordinationError> {
        let json: String = self.database.lock().query_row(
            "SELECT commit_receipt_json FROM cluster_transactions WHERE transaction_id=?1",
            [transaction_id.to_string()],
            |row| row.get(0),
        )?;
        serde_json::from_str(&json).map_err(|error| CoordinationError::Storage(error.to_string()))
    }

    pub(super) fn status(&self, cluster_id: Uuid) -> Result<ClusterStatusRow, CoordinationError> {
        let conn = self.database.lock();
        let (name, state): (String, String) = conn.query_row(
            "SELECT name,state FROM cluster_state WHERE id=?1",
            [cluster_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let mut statement = conn.prepare(
            "SELECT node_id,name,role,reachable,qsfp_health FROM cluster_members WHERE cluster_id=?1 ORDER BY role DESC,node_id"
        )?;
        let members = statement
            .query_map([cluster_id.to_string()], |row| {
                Ok(ClusterMemberRow {
                    node_id: row.get(0)?,
                    name: row.get(1)?,
                    role: row.get(2)?,
                    reachable: row.get::<_, i64>(3)? == 1,
                    qsfp_health: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ClusterStatusRow {
            id: Some(cluster_id.to_string()),
            name: Some(name),
            state,
            members,
        })
    }
}

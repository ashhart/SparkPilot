use super::*;

pub(super) struct CommitProtocol<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) link: &'a dyn ClusterLinkControl,
    pub(super) validation: proof_validation::ProposalValidation<'a>,
    pub(super) repository: transaction_repository::TransactionRepository<'a>,
    pub(super) publisher: event_publisher::CoordinationEvents<'a>,
}

impl CommitProtocol<'_> {
    pub(super) fn commit(
        &self,
        proposal: &ClusterProposal,
        grants: &[ClusterDeviceGrant],
        proofs: &[ClusterLinkProof],
        collectives: &[ClusterCollectiveProof],
        now: OffsetDateTime,
    ) -> Result<ClusterCommitReceipt, CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        self.validation.verify_grant_set(proposal, grants, now)?;
        self.validation.verify_proof_set(proposal, proofs, now)?;
        self.validation
            .verify_collective_set(proposal, collectives, now)?;
        let stored_state: Option<(String, String)> = self
            .database
            .lock()
            .query_row(
                "SELECT proposal_digest, state FROM cluster_transactions WHERE transaction_id = ?1",
                [proposal.transaction_id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((stored_digest, state)) = stored_state else {
            return Err(CoordinationError::Conflict(
                "transaction was not prepared".into(),
            ));
        };
        if stored_digest != proposal.digest()? {
            return Err(CoordinationError::Conflict(
                "prepared proposal digest changed".into(),
            ));
        }
        if matches!(state.as_str(), "committed" | "ready") {
            return self.repository.commit_receipt(proposal.transaction_id);
        }
        if !matches!(state.as_str(), "collective" | "committing") {
            return Err(CoordinationError::Conflict(format!(
                "transaction cannot commit from {state}"
            )));
        }
        if state == "collective" {
            let changed = self.database.lock().execute(
                "UPDATE cluster_transactions SET state = 'committing', updated_at = ?1
                 WHERE transaction_id = ?2 AND state = 'collective'",
                rusqlite::params![
                    crate::store::now_iso8601(),
                    proposal.transaction_id.to_string()
                ],
            )?;
            if changed != 1 {
                return Err(CoordinationError::Conflict(
                    "commit lost its transaction fence".into(),
                ));
            }
        }
        let committed_at = now
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let mut receipt = ClusterCommitReceipt {
            version: PROPOSAL_VERSION,
            transaction_id: proposal.transaction_id,
            cluster_id: proposal.cluster_id,
            proposal_digest: proposal.digest()?,
            member_node_id: self.identity.node_id(),
            committed_at,
            authority_signature: String::new(),
        };
        receipt.authority_signature = crate::crypto::base64url_encode(
            &self
                .identity
                .signing_key()
                .sign(receipt.canonical_without_signature().as_bytes())
                .to_bytes(),
        );
        let receipt_json = serde_json::to_string(&receipt)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let mut conn = self.database.lock();
        let tx = conn.transaction()?;
        let existing: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM cluster_state WHERE singleton = 1)",
            [],
            |row| row.get(0),
        )?;
        if existing {
            drop(tx);
            self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            )?;
            self.database.lock().execute(
                "UPDATE cluster_transactions SET state='rolled_back',updated_at=?1 WHERE transaction_id=?2 AND state='committing'",
                rusqlite::params![crate::store::now_iso8601(), proposal.transaction_id.to_string()],
            )?;
            return Err(CoordinationError::Conflict(
                "this Spark already belongs to a cluster".into(),
            ));
        }
        let timestamp = crate::store::now_iso8601();
        tx.execute(
            "INSERT INTO cluster_state(singleton,id,name,state,created_at,updated_at)
             VALUES(1,?1,?2,?3,?4,?4)",
            rusqlite::params![
                proposal.cluster_id.to_string(),
                proposal.name,
                "forming",
                timestamp
            ],
        )?;
        for member in &proposal.members {
            tx.execute(
                "INSERT INTO cluster_members
                 (cluster_id,node_id,name,role,authority_fingerprint,reachable,
                  runtime_version,last_seen_at,metadata_json)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
                rusqlite::params![
                    proposal.cluster_id.to_string(),
                    member.node_id.to_string(),
                    member.name,
                    if member.node_id == proposal.coordinator_node_id {
                        "leader"
                    } else {
                        "worker"
                    },
                    member.authority_fingerprint,
                    1_i64,
                    member.runtime_version,
                    timestamp,
                    serde_json::json!({ "transaction_id": proposal.transaction_id }).to_string(),
                ],
            )?;
        }
        for grant in grants {
            tx.execute(
                "INSERT INTO cluster_device_grants
                 (cluster_id,transaction_id,member_node_id,device_id,role,device_key_fingerprint,
                  proposal_digest,authority_signature,issued_at,expires_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                rusqlite::params![
                    grant.cluster_id.to_string(),
                    grant.transaction_id.to_string(),
                    grant.member_node_id.to_string(),
                    grant.owner_device_id.to_string(),
                    grant.role,
                    grant.device_key_fingerprint,
                    grant.proposal_digest,
                    grant.authority_signature,
                    grant.issued_at,
                    grant.expires_at,
                ],
            )?;
        }
        for proof in proofs {
            tx.execute(
                "INSERT INTO cluster_link_proofs
                 (cluster_id,member_node_id,peer_node_id,proposal_digest,local_address,
                  peer_address,interface,local_mac,neighbour_mac,speed_mbps,mtu,
                  observed_at,authority_signature)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",
                rusqlite::params![
                    proof.cluster_id.to_string(),
                    proof.member_node_id.to_string(),
                    proof.peer_node_id.to_string(),
                    proof.proposal_digest,
                    proof.local_address.to_string(),
                    proof.peer_address.to_string(),
                    proof.interface,
                    proof.local_mac,
                    proof.neighbour_mac,
                    proof.speed_mbps,
                    proof.mtu,
                    proof.observed_at,
                    proof.authority_signature,
                ],
            )?;
        }
        for proof in collectives {
            tx.execute(
                "INSERT INTO cluster_collective_proofs
                 (cluster_id,member_node_id,proposal_digest,node_rank,measured_latency_us,
                  measured_bandwidth_mbps,operation_elapsed_ms,fabric_auth_json,observed_at,
                  authority_signature)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                rusqlite::params![
                    proof.cluster_id.to_string(),
                    proof.member_node_id.to_string(),
                    proof.proposal_digest,
                    proof.node_rank,
                    proof.measured_latency_us,
                    proof.measured_bandwidth_mbps,
                    proof.operation_elapsed_ms,
                    serde_json::to_string(&proof.fabric_authentication)
                        .map_err(|error| CoordinationError::Storage(error.to_string()))?,
                    proof.observed_at,
                    proof.authority_signature,
                ],
            )?;
        }
        let changed = tx.execute(
            "UPDATE cluster_transactions SET state='committed',commit_receipt_json=?1,updated_at=?2
             WHERE transaction_id=?3 AND state='committing'",
            rusqlite::params![receipt_json, timestamp, proposal.transaction_id.to_string()],
        )?;
        if changed != 1 {
            return Err(CoordinationError::Conflict(
                "commit lost its final transaction fence".into(),
            ));
        }
        tx.commit()?;
        drop(conn);
        self.publisher.emit_cluster_event(
            proposal.cluster_id,
            "cluster.node.joined",
            "notice",
            serde_json::json!({
                "transaction_id": proposal.transaction_id,
                "members": proposal.members.len(),
                "node_ids": proposal.members.iter().map(|member| member.node_id).collect::<Vec<_>>(),
            }),
        );
        Ok(receipt)
    }

    pub(super) fn finalize(
        &self,
        proposal: &ClusterProposal,
        receipts: &[ClusterCommitReceipt],
        now: OffsetDateTime,
    ) -> Result<ClusterStatusRow, CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        self.validation
            .verify_receipt_set(proposal, receipts, now)?;
        let state = self.repository.transaction_state(proposal)?;
        if state == "ready" {
            return self.repository.status(proposal.cluster_id);
        }
        if state != "committed" {
            return Err(CoordinationError::Conflict(format!(
                "transaction cannot finalize from {state}"
            )));
        }
        let stored = self.repository.commit_receipt(proposal.transaction_id)?;
        if !receipts.contains(&stored) {
            return Err(CoordinationError::InvalidGrant(
                "the local durable commit receipt is absent".into(),
            ));
        }
        let now_text = crate::store::now_iso8601();
        let mut connection = self.database.lock();
        let transaction = connection.transaction()?;
        for receipt in receipts {
            transaction.execute(
                "INSERT INTO cluster_commit_receipts
                 (cluster_id,transaction_id,member_node_id,proposal_digest,committed_at,authority_signature)
                 VALUES(?1,?2,?3,?4,?5,?6)",
                rusqlite::params![
                    receipt.cluster_id.to_string(),
                    receipt.transaction_id.to_string(),
                    receipt.member_node_id.to_string(),
                    receipt.proposal_digest,
                    receipt.committed_at,
                    receipt.authority_signature,
                ],
            )?;
        }
        let cluster_changed = transaction.execute(
            "UPDATE cluster_state SET state=?1,updated_at=?2 WHERE id=?3 AND state='forming'",
            rusqlite::params![READY, now_text, proposal.cluster_id.to_string()],
        )?;
        let transaction_changed = transaction.execute(
            "UPDATE cluster_transactions SET state='ready',updated_at=?1
             WHERE transaction_id=?2 AND state='committed'",
            rusqlite::params![now_text, proposal.transaction_id.to_string()],
        )?;
        if cluster_changed != 1 || transaction_changed != 1 {
            return Err(CoordinationError::Conflict(
                "finalize lost its two-sided transaction fence".into(),
            ));
        }
        transaction.commit()?;
        drop(connection);
        self.publisher.emit_cluster_event(
            proposal.cluster_id,
            "cluster.ready",
            "notice",
            serde_json::json!({
                "transaction_id": proposal.transaction_id,
                "members": proposal.members.len(),
            }),
        );
        self.repository.status(proposal.cluster_id)
    }
}

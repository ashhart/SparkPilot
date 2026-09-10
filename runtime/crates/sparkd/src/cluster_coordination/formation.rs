use super::*;

pub(super) struct FormationControl<'a> {
    pub(super) database: &'a Mutex<Connection>,
    pub(super) identity: &'a NodeIdentity,
    pub(super) link: &'a dyn ClusterLinkControl,
    pub(super) validation: proof_validation::ProposalValidation<'a>,
    pub(super) repository: transaction_repository::TransactionRepository<'a>,
    pub(super) publisher: event_publisher::CoordinationEvents<'a>,
    pub(super) collective: &'a Option<Arc<dyn ClusterCollectiveControl>>,
    pub(super) peer_authenticator: &'a Option<Arc<dyn ClusterPeerAuthenticator>>,
}

impl FormationControl<'_> {
    pub(super) fn prepare(
        &self,
        proposal: &ClusterProposal,
        principal_device_id: Uuid,
        now: OffsetDateTime,
    ) -> Result<ClusterDeviceGrant, CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        if proposal.owner_device_id != principal_device_id {
            return Err(CoordinationError::OwnerGrantMissing);
        }
        let device = {
            let conn = self.database.lock();
            crate::store::load_device_by_id(&conn, &principal_device_id)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?
                .filter(|device| matches!(device.role.as_str(), "owner" | "administrator"))
                .ok_or(CoordinationError::OwnerGrantMissing)?
        };
        let digest = proposal.digest()?;
        let issued_at = now
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| CoordinationError::InvalidProposal(error.to_string()))?;
        let device_fingerprint = crate::crypto::sha256_hex(&device.public_key_spki);
        let existing = self
            .repository
            .existing_transaction(proposal.transaction_id)?;
        if existing.is_none() {
            let connection = self.database.lock();
            let already_clustered: bool = connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM cluster_state WHERE singleton=1)",
                [],
                |row| row.get(0),
            )?;
            let another_live_transaction: bool = connection.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM cluster_transactions
                    WHERE transaction_id != ?1
                      AND state NOT IN ('rolled_back','failed')
                 )",
                [proposal.transaction_id.to_string()],
                |row| row.get(0),
            )?;
            if already_clustered || another_live_transaction {
                return Err(CoordinationError::Conflict(
                    "this Spark already has a live cluster or cluster transaction".into(),
                ));
            }
        }
        let (grant, inserted) = if let Some((stored_digest, state, grant_json)) = existing {
            if stored_digest != digest {
                return Err(CoordinationError::Conflict(
                    "transaction id was already used for another proposal".into(),
                ));
            }
            let grant: ClusterDeviceGrant = serde_json::from_str(&grant_json)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            if state != "preparing" {
                if matches!(
                    state.as_str(),
                    "prepared"
                        | "active"
                        | "proved"
                        | "collective"
                        | "committing"
                        | "committed"
                        | "ready"
                ) {
                    return Ok(grant);
                }
                return Err(CoordinationError::Conflict(format!(
                    "transaction cannot prepare from {state}"
                )));
            }
            self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            )?;
            (grant, false)
        } else {
            let mut grant = ClusterDeviceGrant {
                version: PROPOSAL_VERSION,
                transaction_id: proposal.transaction_id,
                cluster_id: proposal.cluster_id,
                proposal_digest: digest.clone(),
                member_node_id: self.identity.node_id(),
                owner_device_id: principal_device_id,
                role: device.role,
                device_key_fingerprint: device_fingerprint,
                issued_at: issued_at.clone(),
                expires_at: proposal.expires_at.clone(),
                authority_signature: String::new(),
            };
            grant.authority_signature = crate::crypto::base64url_encode(
                &self
                    .identity
                    .signing_key()
                    .sign(grant.canonical_without_signature().as_bytes())
                    .to_bytes(),
            );
            let grant_json = serde_json::to_string(&grant)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let proposal_json = serde_json::to_string(proposal)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let (local_address, peer_address) = proposal.addresses_for(self.identity.node_id())?;
            {
                // Remove settled rollback history before inserting a fresh transaction that needs the same unique cluster ID.
                let conn = self.database.lock();
                conn.execute(
                    "DELETE FROM cluster_transactions
                      WHERE cluster_id = ?1
                        AND transaction_id != ?2
                        AND state IN ('rolled_back','failed')",
                    rusqlite::params![
                        proposal.cluster_id.to_string(),
                        proposal.transaction_id.to_string(),
                    ],
                )?;
            }
            self.database.lock().execute(
                "INSERT INTO cluster_transactions
                 (transaction_id, cluster_id, proposal_digest, coordinator_node_id,
                  owner_device_id, local_address, peer_address, state, grant_json,
                  proposal_json, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'preparing', ?8, ?9, ?10, ?10)",
                rusqlite::params![
                    proposal.transaction_id.to_string(),
                    proposal.cluster_id.to_string(),
                    digest,
                    proposal.coordinator_node_id.to_string(),
                    principal_device_id.to_string(),
                    local_address.to_string(),
                    peer_address.to_string(),
                    grant_json,
                    proposal_json,
                    issued_at,
                ],
            )?;
            (grant, true)
        };
        if let Err(error) =
            self.link
                .apply(proposal, self.identity.node_id(), ClusterLinkPhase::Prepare)
        {
            let rollback = self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            );
            if rollback.is_ok() {
                self.database.lock().execute(
                    "DELETE FROM cluster_transactions WHERE transaction_id=?1 AND state='preparing'",
                    [proposal.transaction_id.to_string()],
                )?;
                return Err(error);
            }
            self.database.lock().execute(
                "UPDATE cluster_transactions SET state='rolling_back',updated_at=?1 WHERE transaction_id=?2 AND state='preparing'",
                rusqlite::params![crate::store::now_iso8601(), proposal.transaction_id.to_string()],
            )?;
            return Err(CoordinationError::Link(format!(
                "prepare failed ({error}); rollback could not be confirmed ({})",
                rollback.unwrap_err()
            )));
        }
        let changed = self.database.lock().execute(
            "UPDATE cluster_transactions SET state='prepared',updated_at=?1
             WHERE transaction_id=?2 AND proposal_digest=?3 AND state='preparing'",
            rusqlite::params![
                crate::store::now_iso8601(),
                proposal.transaction_id.to_string(),
                proposal.digest()?,
            ],
        );
        let changed = match changed {
            Ok(1) => 1,
            Ok(changed) => changed,
            Err(error) => {
                let rollback = self.link.apply(
                    proposal,
                    self.identity.node_id(),
                    ClusterLinkPhase::Rollback,
                );
                if rollback.is_err() {
                    self.database.lock().execute(
                        "UPDATE cluster_transactions SET state='rolling_back',updated_at=?1 WHERE transaction_id=?2 AND state='preparing'",
                        rusqlite::params![crate::store::now_iso8601(), proposal.transaction_id.to_string()],
                    )?;
                } else if inserted {
                    self.database.lock().execute(
                        "DELETE FROM cluster_transactions WHERE transaction_id=?1 AND state='preparing'",
                        [proposal.transaction_id.to_string()],
                    )?;
                }
                return Err(error.into());
            }
        };
        if changed != 1 {
            self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            )?;
            return Err(CoordinationError::Conflict(
                "prepare lost its transaction fence".into(),
            ));
        }
        Ok(grant)
    }

    pub(super) fn activate(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<(), CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        let state = self.repository.transaction_state(proposal)?;
        if matches!(state.as_str(), "active" | "proved" | "committed" | "ready") {
            return Ok(());
        }
        if state != "prepared" {
            return Err(CoordinationError::Conflict(format!(
                "transaction cannot activate from {state}"
            )));
        }
        if let Err(activation_error) =
            self.link
                .apply(proposal, self.identity.node_id(), ClusterLinkPhase::Commit)
        {
            return match self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            ) {
                Ok(()) => Err(activation_error),
                Err(rollback_error) => Err(CoordinationError::Link(format!(
                    "activation failed ({activation_error}); rollback could not be confirmed ({rollback_error})"
                ))),
            };
        }
        let changed = match self.database.lock().execute(
            "UPDATE cluster_transactions SET state='active',updated_at=?1
             WHERE transaction_id=?2 AND proposal_digest=?3 AND state='prepared'",
            rusqlite::params![
                crate::store::now_iso8601(),
                proposal.transaction_id.to_string(),
                proposal.digest()?,
            ],
        ) {
            Ok(changed) => changed,
            Err(error) => {
                return match self.link.apply(
                    proposal,
                    self.identity.node_id(),
                    ClusterLinkPhase::Rollback,
                ) {
                    Ok(()) => Err(error.into()),
                    Err(rollback_error) => Err(CoordinationError::Link(format!(
                        "activation state could not be persisted ({error}); rollback could not be confirmed ({rollback_error})"
                    ))),
                };
            }
        };
        if changed != 1 {
            self.link.apply(
                proposal,
                self.identity.node_id(),
                ClusterLinkPhase::Rollback,
            )?;
            return Err(CoordinationError::Conflict(
                "activation lost its transaction fence".into(),
            ));
        }
        self.publisher.emit_cluster_event(
            proposal.cluster_id,
            "cluster.link.changed",
            "notice",
            serde_json::json!({
                "transaction_id": proposal.transaction_id,
                "node_id": self.identity.node_id(),
                "link_up": true,
                "phase": "active",
            }),
        );
        Ok(())
    }

    pub(super) fn prove(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<ClusterLinkProof, CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        let state = self.repository.transaction_state(proposal)?;
        if matches!(state.as_str(), "proved" | "committed" | "ready") {
            let json: String = self.database.lock().query_row(
                "SELECT proof_json FROM cluster_transactions WHERE transaction_id=?1",
                [proposal.transaction_id.to_string()],
                |row| row.get(0),
            )?;
            return serde_json::from_str(&json)
                .map_err(|error| CoordinationError::Storage(error.to_string()));
        }
        if state != "active" {
            return Err(CoordinationError::Conflict(format!(
                "transaction cannot prove its peer from {state}"
            )));
        }
        let mut proof = self.link.prove(proposal, self.identity.node_id())?;
        proof.observed_at = now
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        proof.authority_signature = crate::crypto::base64url_encode(
            &self
                .identity
                .signing_key()
                .sign(proof.canonical_without_signature().as_bytes())
                .to_bytes(),
        );
        let local = proposal
            .members
            .iter()
            .find(|member| member.node_id == self.identity.node_id())
            .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
        proof.verify(proposal, local, now)?;
        let proof_json = serde_json::to_string(&proof)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let changed = self.database.lock().execute(
            "UPDATE cluster_transactions SET state='proved',proof_json=?1,updated_at=?2
             WHERE transaction_id=?3 AND proposal_digest=?4 AND state='active'",
            rusqlite::params![
                proof_json,
                crate::store::now_iso8601(),
                proposal.transaction_id.to_string(),
                proposal.digest()?,
            ],
        )?;
        if changed != 1 {
            return Err(CoordinationError::Conflict(
                "peer proof lost its transaction fence".into(),
            ));
        }
        self.publisher.emit_cluster_event(
            proposal.cluster_id,
            "cluster.validation.progress",
            "info",
            serde_json::json!({
                "transaction_id": proposal.transaction_id,
                "node_id": self.identity.node_id(),
                "stage": "reciprocal_link_proved",
                "interface": proof.interface,
                "speed_mbps": proof.speed_mbps,
                "mtu": proof.mtu,
            }),
        );
        Ok(proof)
    }

    pub(super) fn run_collective(
        &self,
        proposal: &ClusterProposal,
        now: OffsetDateTime,
    ) -> Result<ClusterCollectiveProof, CoordinationError> {
        self.validation.validate_proposal(proposal, now)?;
        let state = self.repository.transaction_state(proposal)?;
        if matches!(state.as_str(), "collective" | "committed" | "ready") {
            let json: String = self.database.lock().query_row(
                "SELECT collective_json FROM cluster_transactions WHERE transaction_id=?1",
                [proposal.transaction_id.to_string()],
                |row| row.get(0),
            )?;
            return serde_json::from_str(&json)
                .map_err(|error| CoordinationError::Storage(error.to_string()));
        }
        if state != "proved" {
            return Err(CoordinationError::Conflict(format!(
                "transaction cannot run its collective from {state}"
            )));
        }
        let local = proposal
            .members
            .iter()
            .find(|member| member.node_id == self.identity.node_id())
            .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
        let cached_authentication: Option<String> = self.database.lock().query_row(
            "SELECT fabric_auth_json FROM cluster_transactions WHERE transaction_id=?1",
            [proposal.transaction_id.to_string()],
            |row| row.get(0),
        )?;
        let fabric_authentication = if let Some(json) = cached_authentication {
            serde_json::from_str(&json)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?
        } else {
            let authentication = self
                .peer_authenticator
                .as_ref()
                .ok_or_else(|| {
                    CoordinationError::Link("fabric peer authenticator is unavailable".into())
                })?
                .authenticate(proposal, self.identity, now)?;
            let verified_at = authentication.verification_instant(now);
            authentication.verify(proposal, local, verified_at)?;
            let json = serde_json::to_string(&authentication)
                .map_err(|error| CoordinationError::Storage(error.to_string()))?;
            let changed = self.database.lock().execute(
                "UPDATE cluster_transactions SET fabric_auth_json=?1,updated_at=?2
                 WHERE transaction_id=?3 AND proposal_digest=?4 AND state='proved'
                 AND fabric_auth_json IS NULL",
                rusqlite::params![
                    json,
                    crate::store::now_iso8601(),
                    proposal.transaction_id.to_string(),
                    proposal.digest()?,
                ],
            )?;
            if changed != 1 {
                return Err(CoordinationError::Conflict(
                    "fabric authentication lost its transaction fence".into(),
                ));
            }
            authentication
        };
        let fabric_verified_at = fabric_authentication.verification_instant(now);
        fabric_authentication.verify(proposal, local, fabric_verified_at)?;
        let mut proof = self
            .collective
            .as_ref()
            .ok_or_else(|| CoordinationError::Link("collective backend is unavailable".into()))?
            .run(proposal, self.identity.node_id())?;
        let elapsed_ms = i64::try_from(proof.operation_elapsed_ms)
            .map_err(|_| CoordinationError::Link("collective duration overflowed".into()))?;
        let completed_at = now + time::Duration::milliseconds(elapsed_ms);
        proof.fabric_authentication = Some(fabric_authentication);
        proof.observed_at = completed_at
            .format(&time::format_description::well_known::Rfc3339)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        proof.authority_signature = crate::crypto::base64url_encode(
            &self
                .identity
                .signing_key()
                .sign(proof.canonical_without_signature().as_bytes())
                .to_bytes(),
        );
        proof.verify(proposal, local, completed_at)?;
        let json = serde_json::to_string(&proof)
            .map_err(|error| CoordinationError::Storage(error.to_string()))?;
        let changed = self.database.lock().execute(
            "UPDATE cluster_transactions SET state='collective',collective_json=?1,updated_at=?2
             WHERE transaction_id=?3 AND proposal_digest=?4 AND state='proved'",
            rusqlite::params![
                json,
                crate::store::now_iso8601(),
                proposal.transaction_id.to_string(),
                proposal.digest()?,
            ],
        )?;
        if changed != 1 {
            return Err(CoordinationError::Conflict(
                "collective proof lost its transaction fence".into(),
            ));
        }
        self.publisher.emit_cluster_event(
            proposal.cluster_id,
            "cluster.validation.progress",
            "info",
            serde_json::json!({
                "transaction_id": proposal.transaction_id,
                "node_id": self.identity.node_id(),
                "stage": "two_rank_collective_proved",
                "rank": proof.node_rank,
            }),
        );
        Ok(proof)
    }
}

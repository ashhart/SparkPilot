use super::*;

#[derive(Clone)]
pub struct TcpClusterPeerAuthenticator {
    pub(super) port: u16,
    pub(super) socket_address_override: Option<(Ipv4Addr, Ipv4Addr)>,
}

impl Default for TcpClusterPeerAuthenticator {
    fn default() -> Self {
        Self {
            port: CLUSTER_FABRIC_CHALLENGE_PORT,
            socket_address_override: None,
        }
    }
}

impl TcpClusterPeerAuthenticator {
    fn socket_addresses(&self, hello: &FabricChallengeHello) -> (Ipv4Addr, Ipv4Addr) {
        self.socket_address_override
            .unwrap_or((hello.initiator_address, hello.responder_address))
    }
}

pub(super) fn write_fabric_message<T: Serialize>(
    stream: &mut TcpStream,
    value: &T,
) -> Result<(), CoordinationError> {
    let bytes =
        serde_json::to_vec(value).map_err(|error| CoordinationError::Link(error.to_string()))?;
    if bytes.len() > 16 * 1024 {
        return Err(CoordinationError::Link(
            "fabric challenge message exceeded its bound".into(),
        ));
    }
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|_| stream.write_all(&bytes))
        .map_err(|error| CoordinationError::Link(format!("fabric challenge write failed: {error}")))
}

pub(super) fn read_fabric_message<T: for<'de> Deserialize<'de>>(
    stream: &mut TcpStream,
) -> Result<T, CoordinationError> {
    let mut length = [0_u8; 4];
    stream.read_exact(&mut length).map_err(|error| {
        CoordinationError::Link(format!("fabric challenge read failed: {error}"))
    })?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > 16 * 1024 {
        return Err(CoordinationError::Link(
            "fabric challenge frame length was rejected".into(),
        ));
    }
    let mut bytes = vec![0_u8; length];
    stream.read_exact(&mut bytes).map_err(|error| {
        CoordinationError::Link(format!("fabric challenge read failed: {error}"))
    })?;
    serde_json::from_slice(&bytes)
        .map_err(|_| CoordinationError::Link("fabric challenge message was malformed".into()))
}

pub(super) fn random_fabric_nonce() -> String {
    let mut nonce = [0_u8; 32];
    rand::rng().fill_bytes(&mut nonce);
    crate::crypto::base64url_encode(&nonce)
}

pub(super) fn rfc3339(value: OffsetDateTime) -> Result<String, CoordinationError> {
    value
        .format(&time::format_description::well_known::Rfc3339)
        .map_err(|error| CoordinationError::Link(error.to_string()))
}

pub(super) fn sign_fabric(identity: &NodeIdentity, value: &str) -> String {
    crate::crypto::base64url_encode(&identity.signing_key().sign(value.as_bytes()).to_bytes())
}

pub(super) fn base_fabric_hello(
    proposal: &ClusterProposal,
    initiated_at: String,
    initiator_nonce: String,
) -> Result<FabricChallengeHello, CoordinationError> {
    let mut ordered = proposal.members.iter().collect::<Vec<_>>();
    ordered.sort_by_key(|member| member.node_id);
    let responder = ordered[0];
    let initiator = ordered[1];
    let (initiator_address, responder_address) = proposal.addresses_for(initiator.node_id)?;
    Ok(FabricChallengeHello {
        version: PROPOSAL_VERSION,
        transaction_id: proposal.transaction_id,
        cluster_id: proposal.cluster_id,
        proposal_digest: proposal.digest()?,
        initiator_node_id: initiator.node_id,
        responder_node_id: responder.node_id,
        initiator_address,
        responder_address,
        initiator_authority_public_key: initiator.authority_public_key.clone(),
        responder_authority_public_key: responder.authority_public_key.clone(),
        initiator_nonce,
        initiated_at,
        initiator_signature: String::new(),
    })
}

pub(super) fn validate_hello(
    hello: &FabricChallengeHello,
    proposal: &ClusterProposal,
) -> Result<(), CoordinationError> {
    let expected = base_fabric_hello(
        proposal,
        hello.initiated_at.clone(),
        hello.initiator_nonce.clone(),
    )?;
    // Reject zero nonces before exchange so responders and proof verification enforce the same nonce policy.
    let nonce_bytes = crate::crypto::base64url_decode(&hello.initiator_nonce)
        .map_err(|_| CoordinationError::InvalidProposal("fabric nonce is not base64url".into()))?;
    if nonce_bytes.len() != 32 || nonce_bytes.iter().all(|byte| *byte == 0) {
        return Err(CoordinationError::InvalidProposal(
            "fabric challenge nonce is degenerate".into(),
        ));
    }
    if hello.version != expected.version
        || hello.transaction_id != expected.transaction_id
        || hello.cluster_id != expected.cluster_id
        || hello.proposal_digest != expected.proposal_digest
        || hello.initiator_node_id != expected.initiator_node_id
        || hello.responder_node_id != expected.responder_node_id
        || hello.initiator_address != expected.initiator_address
        || hello.responder_address != expected.responder_address
        || hello.initiator_authority_public_key != expected.initiator_authority_public_key
        || hello.responder_authority_public_key != expected.responder_authority_public_key
        || !crate::crypto::base64url_decode(&hello.initiator_nonce)
            .is_ok_and(|bytes| bytes.len() == 32)
    {
        return Err(CoordinationError::Link(
            "fabric hello was substituted or rebound".into(),
        ));
    }
    verify_authority_signature(
        &hello.initiator_signature,
        &decode_verifying_key(&hello.initiator_authority_public_key)?,
        hello.canonical_without_signature().as_bytes(),
        "fabric initiator signature",
    )
}

pub(super) fn finish_fabric_proof(
    proposal: &ClusterProposal,
    identity: &NodeIdentity,
    hello: FabricChallengeHello,
    response: FabricChallengeResponse,
    acknowledgement: FabricChallengeAcknowledgement,
    completion: FabricChallengeCompletion,
    observed_at: OffsetDateTime,
) -> Result<ClusterFabricAuthenticationProof, CoordinationError> {
    let mut proof = ClusterFabricAuthenticationProof {
        version: PROPOSAL_VERSION,
        transaction_id: proposal.transaction_id,
        cluster_id: proposal.cluster_id,
        proposal_digest: proposal.digest()?,
        member_node_id: identity.node_id(),
        initiator_node_id: hello.initiator_node_id,
        responder_node_id: hello.responder_node_id,
        initiator_address: hello.initiator_address,
        responder_address: hello.responder_address,
        initiator_authority_public_key: hello.initiator_authority_public_key,
        responder_authority_public_key: hello.responder_authority_public_key,
        initiator_nonce: hello.initiator_nonce,
        responder_nonce: response.responder_nonce,
        initiated_at: hello.initiated_at,
        responded_at: response.responded_at,
        initiator_signature: hello.initiator_signature,
        responder_signature: response.responder_signature,
        acknowledgement_signature: acknowledgement.acknowledgement_signature,
        completion_signature: completion.completion_signature,
        observed_at: rfc3339(observed_at)?,
        authority_signature: String::new(),
    };
    proof.authority_signature = sign_fabric(identity, &proof.canonical_without_signature());
    let member = proposal
        .members
        .iter()
        .find(|member| member.node_id == identity.node_id())
        .ok_or_else(|| CoordinationError::InvalidProposal("local Spark is absent".into()))?;
    proof.verify(proposal, member, observed_at)?;
    Ok(proof)
}

pub(super) fn prepare_fabric_stream(stream: &TcpStream) -> Result<(), CoordinationError> {
    stream
        .set_nonblocking(false)
        .and_then(|_| stream.set_read_timeout(Some(Duration::from_secs(10))))
        .and_then(|_| stream.set_write_timeout(Some(Duration::from_secs(10))))
        .and_then(|_| stream.set_nodelay(true))
        .map_err(|error| CoordinationError::Link(format!("fabric socket setup failed: {error}")))
}

impl ClusterPeerAuthenticator for TcpClusterPeerAuthenticator {
    fn authenticate(
        &self,
        proposal: &ClusterProposal,
        identity: &NodeIdentity,
        now: OffsetDateTime,
    ) -> Result<ClusterFabricAuthenticationProof, CoordinationError> {
        let mut hello = base_fabric_hello(proposal, rfc3339(now)?, random_fabric_nonce())?;
        let initiator_key = decode_verifying_key(&hello.initiator_authority_public_key)?;
        let responder_key = decode_verifying_key(&hello.responder_authority_public_key)?;
        let (initiator_socket_address, responder_socket_address) = self.socket_addresses(&hello);
        if identity.node_id() == hello.initiator_node_id {
            hello.initiator_signature = sign_fabric(identity, &hello.canonical_without_signature());
            let peer = SocketAddr::V4(SocketAddrV4::new(responder_socket_address, self.port));
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut stream = loop {
                match TcpStream::connect_timeout(&peer, Duration::from_millis(500)) {
                    Ok(stream) => break stream,
                    Err(_) if Instant::now() < deadline => {
                        thread::sleep(Duration::from_millis(100));
                    }
                    Err(error) => {
                        return Err(CoordinationError::Link(format!(
                            "the CX-7 peer challenge could not connect: {error}"
                        )));
                    }
                }
            };
            prepare_fabric_stream(&stream)?;
            if stream.local_addr().ok().map(|address| address.ip())
                != Some(std::net::IpAddr::V4(initiator_socket_address))
                || stream.peer_addr().ok() != Some(peer)
            {
                return Err(CoordinationError::Link(
                    "the peer challenge did not use the proposed CX-7 endpoints".into(),
                ));
            }
            write_fabric_message(&mut stream, &hello)?;
            let response: FabricChallengeResponse = read_fabric_message(&mut stream)?;
            verify_authority_signature(
                &response.responder_signature,
                &responder_key,
                hello.response_canonical(&response).as_bytes(),
                "fabric responder signature",
            )?;
            let mut acknowledgement = FabricChallengeAcknowledgement {
                acknowledgement_signature: String::new(),
            };
            acknowledgement.acknowledgement_signature =
                sign_fabric(identity, &hello.acknowledgement_canonical(&response));
            write_fabric_message(&mut stream, &acknowledgement)?;
            let completion: FabricChallengeCompletion = read_fabric_message(&mut stream)?;
            verify_authority_signature(
                &completion.completion_signature,
                &responder_key,
                hello
                    .completion_canonical(&response, &acknowledgement)
                    .as_bytes(),
                "fabric completion signature",
            )?;
            finish_fabric_proof(
                proposal,
                identity,
                hello,
                response,
                acknowledgement,
                completion,
                OffsetDateTime::now_utc(),
            )
        } else if identity.node_id() == hello.responder_node_id {
            let listener = TcpListener::bind(SocketAddrV4::new(
                responder_socket_address,
                self.port,
            ))
            .map_err(|error| {
                CoordinationError::Link(format!("the CX-7 challenge listener failed: {error}"))
            })?;
            listener.set_nonblocking(true).map_err(|error| {
                CoordinationError::Link(format!("fabric listener setup failed: {error}"))
            })?;
            let deadline = Instant::now() + Duration::from_secs(10);
            let (mut stream, peer) = loop {
                match listener.accept() {
                    Ok(value) => break value,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(25));
                    }
                    Err(error) => {
                        return Err(CoordinationError::Link(format!(
                            "the CX-7 challenge accept failed: {error}"
                        )));
                    }
                }
            };
            prepare_fabric_stream(&stream)?;
            if peer.ip() != std::net::IpAddr::V4(initiator_socket_address)
                || stream.local_addr().ok().map(|address| address.ip())
                    != Some(std::net::IpAddr::V4(responder_socket_address))
            {
                return Err(CoordinationError::Link(
                    "the incoming challenge did not use the proposed CX-7 endpoints".into(),
                ));
            }
            hello = read_fabric_message(&mut stream)?;
            validate_hello(&hello, proposal)?;
            let mut response = FabricChallengeResponse {
                responder_nonce: random_fabric_nonce(),
                responded_at: rfc3339(OffsetDateTime::now_utc())?,
                responder_signature: String::new(),
            };
            response.responder_signature =
                sign_fabric(identity, &hello.response_canonical(&response));
            write_fabric_message(&mut stream, &response)?;
            let acknowledgement: FabricChallengeAcknowledgement = read_fabric_message(&mut stream)?;
            verify_authority_signature(
                &acknowledgement.acknowledgement_signature,
                &initiator_key,
                hello.acknowledgement_canonical(&response).as_bytes(),
                "fabric acknowledgement signature",
            )?;
            let completion = FabricChallengeCompletion {
                completion_signature: sign_fabric(
                    identity,
                    &hello.completion_canonical(&response, &acknowledgement),
                ),
            };
            write_fabric_message(&mut stream, &completion)?;
            finish_fabric_proof(
                proposal,
                identity,
                hello,
                response,
                acknowledgement,
                completion,
                OffsetDateTime::now_utc(),
            )
        } else {
            Err(CoordinationError::InvalidProposal(
                "local Spark is absent from the fabric challenge".into(),
            ))
        }
    }
}

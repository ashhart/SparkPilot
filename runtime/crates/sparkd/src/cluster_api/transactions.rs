use super::*;

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct CommitClusterTransactionBody {
    pub proposal: crate::cluster_coordination::ClusterProposal,
    pub grants: Vec<crate::cluster_coordination::ClusterDeviceGrant>,
    pub proofs: Vec<crate::cluster_coordination::ClusterLinkProof>,
    pub collectives: Vec<crate::cluster_coordination::ClusterCollectiveProof>,
}

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct RollbackClusterTransactionBody {
    pub proposal: crate::cluster_coordination::ClusterProposal,
}

#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct FinalizeClusterTransactionBody {
    pub proposal: crate::cluster_coordination::ClusterProposal,
    pub receipts: Vec<crate::cluster_coordination::ClusterCommitReceipt>,
}

/// Return this member's signed prepare grant; commit requires one matching grant from every member.
pub async fn prepare_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(proposal): axum::Json<crate::cluster_coordination::ClusterProposal>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay));
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        PREPARE_TRANSACTION_ROUTE,
        "cluster.transaction.prepare",
        proposal.transaction_id,
        proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let worker = coordinator.clone();
    let grant =
        tokio::task::spawn_blocking(move || worker.prepare(&proposal, principal.device_id, now))
            .await
            .map_err(|error| internal_envelope(&error.to_string()))?
            .map_err(coordination_error)?;
    let outcome = store_transaction_response(&state, &idempotency, &grant)?;
    Ok(json_response(&outcome))
}

pub async fn activate_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(proposal): axum::Json<crate::cluster_coordination::ClusterProposal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay).1);
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        ACTIVATE_TRANSACTION_ROUTE,
        "cluster.transaction.activate",
        proposal.transaction_id,
        proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let transaction_id = proposal.transaction_id;
    let worker = coordinator.clone();
    tokio::task::spawn_blocking(move || worker.activate(&proposal, now))
        .await
        .map_err(|error| internal_envelope(&error.to_string()))?
        .map_err(coordination_error)?;
    let response = json!({ "transaction_id": transaction_id, "state": "active" });
    let outcome = store_transaction_response(&state, &idempotency, &response)?;
    Ok(json_response(&outcome).1)
}

pub async fn prove_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(proposal): axum::Json<crate::cluster_coordination::ClusterProposal>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay));
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        PROVE_TRANSACTION_ROUTE,
        "cluster.transaction.prove",
        proposal.transaction_id,
        proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let worker = coordinator.clone();
    let proof = tokio::task::spawn_blocking(move || worker.prove(&proposal, now))
        .await
        .map_err(|error| internal_envelope(&error.to_string()))?
        .map_err(coordination_error)?;
    let outcome = store_transaction_response(&state, &idempotency, &proof)?;
    Ok(json_response(&outcome))
}

/// Run both NCCL ranks concurrently and require matching signed rank-zero and rank-one proofs for final commit.
pub async fn run_cluster_collective(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(proposal): axum::Json<crate::cluster_coordination::ClusterProposal>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay));
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        COLLECTIVE_TRANSACTION_ROUTE,
        "cluster.transaction.collective",
        proposal.transaction_id,
        proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let worker = coordinator.clone();
    let proof = tokio::task::spawn_blocking(move || worker.run_collective(&proposal, now))
        .await
        .map_err(|error| internal_envelope(&error.to_string()))?
        .map_err(coordination_error)?;
    let outcome = store_transaction_response(&state, &idempotency, &proof)?;
    Ok(json_response(&outcome))
}

pub async fn commit_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<CommitClusterTransactionBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay));
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        COMMIT_TRANSACTION_ROUTE,
        "cluster.transaction.commit",
        body.proposal.transaction_id,
        body.proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let worker = coordinator.clone();
    let status = tokio::task::spawn_blocking(move || {
        worker.commit(
            &body.proposal,
            &body.grants,
            &body.proofs,
            &body.collectives,
            now,
        )
    })
    .await
    .map_err(|error| internal_envelope(&error.to_string()))?
    .map_err(coordination_error)?;
    let outcome = store_transaction_response(&state, &idempotency, &status)?;
    Ok(json_response(&outcome))
}

pub async fn finalize_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<FinalizeClusterTransactionBody>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay));
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        FINALIZE_TRANSACTION_ROUTE,
        "cluster.transaction.finalize",
        body.proposal.transaction_id,
        body.proposal.cluster_id,
    )?;
    let now = state.clock.now();
    let worker = coordinator.clone();
    let status =
        tokio::task::spawn_blocking(move || worker.finalize(&body.proposal, &body.receipts, now))
            .await
            .map_err(|error| internal_envelope(&error.to_string()))?
            .map_err(coordination_error)?;
    let outcome = store_transaction_response(&state, &idempotency, &status)?;
    Ok(json_response(&outcome))
}

pub async fn rollback_cluster_transaction(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    axum::Json(body): axum::Json<RollbackClusterTransactionBody>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    require_cluster_owner_presence(&state, &principal, &authenticated_request, &headers)?;
    let coordinator = state.cluster_coordination.clone().ok_or_else(|| {
        cluster_envelope(
            "CLUSTER_MANAGEMENT_UNAVAILABLE",
            "this runtime has no cluster transaction backend",
            StatusCode::SERVICE_UNAVAILABLE,
        )
    })?;
    let _transaction = coordinator.transaction_guard().await;
    let replay = {
        let _admission = state.idempotency.admission_guard();
        lookup_transaction_replay(&state, &idempotency)?
    };
    if let Some(replay) = replay {
        return Ok(json_response(&replay).1);
    }
    append_transaction_acceptance(
        &state,
        &principal,
        &idempotency,
        ROLLBACK_TRANSACTION_ROUTE,
        "cluster.transaction.rollback",
        body.proposal.transaction_id,
        body.proposal.cluster_id,
    )?;
    let transaction_id = body.proposal.transaction_id;
    let worker = coordinator.clone();
    tokio::task::spawn_blocking(move || worker.rollback(&body.proposal))
        .await
        .map_err(|error| internal_envelope(&error.to_string()))?
        .map_err(coordination_error)?;
    let response = json!({ "transaction_id": transaction_id, "state": "rolled_back" });
    let outcome = store_transaction_response(&state, &idempotency, &response)?;
    Ok(json_response(&outcome).1)
}

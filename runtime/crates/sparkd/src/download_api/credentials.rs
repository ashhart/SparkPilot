use super::*;

pub async fn list_credentials(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::CredentialManage)
        .resource("credentials")
        .check()?;
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let items = CredentialStore::with_clock(&state.config.data_dir, state.clock.clone())
        .list(&database.lock())
        .map_err(|error| internal_envelope(&error))?
        .into_iter()
        .map(|credential| {
            json!({
                "id": credential.id,
                "provider": credential.provider,
                "display_name": credential.display_name,
                "created_at": credential.created_at,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({ "items": items })))
}

pub(super) fn verify_credential_presence(
    state: &AppState,
    principal: &Principal,
    authenticated_request: &AuthenticatedRequest,
    headers: &HeaderMap,
    idempotency: &IdempotencyRequest,
    action: &str,
    resource: &str,
) -> Result<(), (StatusCode, Json<Value>)> {
    let database = state
        .database
        .as_ref()
        .ok_or_else(|| internal_envelope("no database"))?;
    let presence_key =
        crate::store::load_presence_key_by_device_id(&database.lock(), &principal.device_id)
            .map_err(|error| internal_envelope(&error.to_string()))?;
    if let Err(error) = crate::user_presence::verify(
        headers.get(crate::user_presence::HEADER_USER_PRESENCE),
        presence_key.as_deref(),
        authenticated_request,
        state.clock.now(),
    ) {
        crate::audit::append_refusal(
            database,
            state.clock.as_ref(),
            principal.device_id,
            &principal.role,
            &authenticated_request.path_and_query,
            action,
            Some(resource),
            idempotency.request_id,
            error.code(),
        )
        .map_err(crate::audit::unavailable_envelope)?;
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({
                "error": {
                    "code": error.code(),
                    "message": "fresh user presence is required to change provider credentials",
                    "request_id": idempotency.request_id,
                }
            })),
        ));
    }
    Ok(())
}

/// Add an administrator-managed provider credential.
pub async fn add_credential(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    Json(request): Json<AddCredentialRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::CredentialManage)
        .resource("credentials")
        .check()?;
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut db.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    verify_credential_presence(
        &state,
        &principal,
        &authenticated_request,
        &headers,
        &idempotency,
        "credential.add",
        "credentials",
    )?;
    let conn = db.lock();
    let store = CredentialStore::with_clock(&state.config.data_dir, state.clock.clone());
    let response = match store.store(
        &conn,
        &request.provider,
        &request.display_name,
        request.secret.expose_secret(),
        principal.device_id,
    ) {
        Ok(id) => match store.list(&conn).and_then(|records| {
            records
                .into_iter()
                .find(|record| record.id == id)
                .ok_or_else(|| "stored provider credential is unavailable".to_owned())
        }) {
            Ok(record) => StoredResponse {
                status: StatusCode::CREATED,
                body: json!({
                    "id": record.id,
                    "provider": record.provider,
                    "display_name": record.display_name,
                    "created_at": record.created_at,
                }),
                operation_id: None,
            },
            Err(error) => {
                let (status, Json(body)) = internal_envelope(&error);
                StoredResponse {
                    status,
                    body,
                    operation_id: None,
                }
            }
        },
        Err(error) => {
            let (status, Json(body)) = internal_envelope(&error);
            StoredResponse {
                status,
                body,
                operation_id: None,
            }
        }
    };
    drop(conn);
    let outcome = state
        .idempotency
        .execute(&mut db.lock(), &idempotency, |_| Ok(response))
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

/// Revoke an administrator-managed provider credential.
pub async fn revoke_credential(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated_request): Extension<AuthenticatedRequest>,
    headers: HeaderMap,
    idempotency: IdempotencyRequest,
    RoutePath(id): RoutePath<uuid::Uuid>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::CredentialManage)
        .resource(format!("credential/{id}"))
        .check()?;
    let Some(db) = &state.database else {
        return Err(internal_envelope("no database"));
    };
    let _admission = state.idempotency.admission_guard();
    if let Some(outcome) = state
        .idempotency
        .lookup(&mut db.lock(), &idempotency)
        .map_err(|error| error.envelope())?
    {
        return if outcome.response.status.is_success() {
            Ok(json_response(&outcome))
        } else {
            Err(json_response(&outcome))
        };
    }
    verify_credential_presence(
        &state,
        &principal,
        &authenticated_request,
        &headers,
        &idempotency,
        "credential.revoke",
        &format!("credential/{id}"),
    )?;
    let conn = db.lock();
    let store = CredentialStore::with_clock(&state.config.data_dir, state.clock.clone());
    let response = match store.revoke(&conn, id) {
        Ok(()) => StoredResponse {
            status: StatusCode::NO_CONTENT,
            body: Value::Null,
            operation_id: None,
        },
        Err(error) => {
            let (status, Json(body)) = internal_envelope(&error);
            StoredResponse {
                status,
                body,
                operation_id: None,
            }
        }
    };
    drop(conn);
    let outcome = state
        .idempotency
        .execute(&mut db.lock(), &idempotency, |_| Ok(response))
        .map_err(|error| error.envelope())?;
    if outcome.response.status.is_success() {
        Ok(json_response(&outcome))
    } else {
        Err(json_response(&outcome))
    }
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct AddCredentialRequest {
    pub provider: String,
    pub display_name: String,
    pub secret: SecretString,
}

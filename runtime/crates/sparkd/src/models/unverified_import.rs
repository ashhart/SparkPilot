use super::*;

/// Require administrator authority and explicit runtime policy for unsigned imports.
pub async fn import_unverified_model(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    idempotency: IdempotencyRequest,
    Json(request): Json<ImportUnverifiedRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    state
        .require(&principal, crate::capability::Capability::RecipeImport)
        .resource("models/import")
        .check()?;
    let inventory = state.models.as_ref().ok_or(internal_error())?.snapshot();
    if !inventory.allow_unverified_import {
        return Err((
            StatusCode::FORBIDDEN,
            Json(
                json!({ "error": { "code": "MODEL_RECIPE_UNTRUSTED", "message": "unverified import is disabled" } }),
            ),
        ));
    }
    let id = format!("{}/{}", request.repository, request.revision);
    // Reject dot, empty and nonallowlisted identifier segments.
    let safe = !id.is_empty()
        && id.len() <= 240
        && !id
            .split('/')
            .any(|segment| segment.is_empty() || segment == "." || segment == "..")
        && id.chars().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '/' | '-')
        });
    if !safe {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(
                json!({ "error": { "code": "MODEL_RECIPE_INVALID", "message": "invalid model id" } }),
            ),
        ));
    }
    // Validate revision paths before inserting inventory so imports cannot create permanently uninstallable entries.
    if let Err(reason) = crate::model_paths::validate_revision(&request.revision) {
        return Err((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({
                "error": {
                    "code": "MODEL_RECIPE_INVALID",
                    "message": format!("revision cannot be used as a snapshot path: {reason}")
                }
            })),
        ));
    }
    let Some(conn) = &state.database else {
        return Err(internal_error());
    };
    let mut guard = conn.lock();
    let outcome = state
        .idempotency
        .execute(&mut guard, &idempotency, |transaction| {
            // Create a local unverified record; the recipe is deliberately NOT signed.
            store::upsert_catalogue_model(
                transaction,
                &unverified_recipe(&id, &request.repository, &request.revision),
            )?;
            // Reject imports colliding with installed signed models rather than reporting success for writes that made no changes.
            if !store::mark_model_unverified(transaction, &id)? {
                return Ok(StoredResponse {
                    status: StatusCode::CONFLICT,
                    body: json!({
                        "error": {
                            "code": "MODEL_ALREADY_INSTALLED",
                            "message":
                                "A verified model with this id is already installed. \
                                 Remove it before importing an unverified model over it."
                        }
                    }),
                    operation_id: None,
                });
            }
            Ok(StoredResponse {
                status: StatusCode::CREATED,
                body: json!({
                    "id": id,
                    "install_state": "unverified",
                    "warning": "Unverified - may fail or destabilise the node"
                }),
                operation_id: None,
            })
        })
        .map_err(|error| error.envelope())?;
    Ok(json_response(&outcome))
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct ImportUnverifiedRequest {
    pub repository: String,
    pub revision: String,
}

/// Preserve the caller's immutable revision in unsigned recipes so later path validation and installation can succeed.
pub(super) fn unverified_recipe(id: &str, repository: &str, revision: &str) -> ModelRecipe {
    // Never fabricate a signature; retain unverified install state.
    let mut recipe = serde_json::from_value::<ModelRecipe>(json!({
        "apiVersion": "spark.runtime/v1",
        "kind": "ModelRecipe",
        "metadata": {
            "id": id,
            "revision": "unverified",
            "displayName": id,
            "publisher": "local"
        },
        "source": {
            "provider": "huggingface",
            "repository": repository,
            "revision": revision,
            "gated": false,
            "trustRemoteCode": false
        },
        "engine": {
            "recipe": "vllm-dgx-spark-2026-08",
            "image": "nvcr.io/nvidia/vllm@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "servedName": id,
            "task": "generate"
        },
        "capabilities": { "chat": true, "reasoning": false, "toolCalling": false,
                          "parallelToolCalling": false, "guidedGeneration": false,
                          "vision": false, "embeddings": false, "audioInput": false },
        "memory": {
            "minimumSystemReserveBytes": 23622320128i64,
            "expectedWeightBytes": 1,
            "expectedEngineOverheadBytes": 0,
            "measurementConfidence": "unknown"
        },
        "profiles": [{
            "id": "conservative-16k",
            "displayName": "Conservative 16K",
            "maxModelLength": 16384,
            "maxSequences": 2,
            "maxBatchedTokens": 4096,
            "gpuMemoryUtilisation": 0.5,
            "expectedPeakBytes": 30000000000i64,
            "idlePolicy": "manual_only"
        }],
        "security": { "allowNetworkDuringInference": false, "allowedMediaRoots": [],
                      "allowCustomLogitsProcessors": false, "allowPlugins": [] },
        "signature": { "keyID": "unverified-local", "algorithm": "ed25519", "value": "" }
    }))
    .expect("unverified recipe is structurally valid");
    recipe.signature.value = format!("unverified-{}", crate::crypto::sha256_hex(id.as_bytes()));
    recipe
}

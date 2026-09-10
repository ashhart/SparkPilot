use super::*;

#[derive(Debug, thiserror::Error)]
pub enum CatalogueRefreshError {
    #[error("catalogue refresh is not configured")]
    Unavailable,
    #[error("catalogue entry is not a regular file: {0}")]
    NonRegular(String),
    #[error("catalogue exceeds the {MAX_CATALOGUE_BYTES}-byte limit")]
    TooLarge,
    #[error("catalogue JSON is invalid: {0}")]
    InvalidJson(String),
    #[error("catalogue signature or recipe verification failed: {0}")]
    Verification(String),
    #[error("catalogue contains duplicate model id {0}")]
    DuplicateModel(String),
    #[error("catalogue omits installed model ids: {0}")]
    InstalledModelDropped(String),
    #[error("catalogue changes an installed model recipe: {0}")]
    InstalledModelChanged(String),
    #[error(
        "catalogue profile update must wait for model operations and cluster launches to stop: {0}"
    )]
    ModelInUse(String),
    #[error("finish the interrupted catalogue refresh before applying a different snapshot")]
    RecoveryRequired,
    #[error("catalogue refresh is blocked while a model installation is in progress")]
    InstallInProgress,
    #[error("catalogue promotion failed: {0}")]
    Promotion(String),
    #[error("catalogue persistence failed: {0}")]
    Persistence(String),
}

impl CatalogueRefreshError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unavailable => "CATALOGUE_REFRESH_UNAVAILABLE",
            Self::NonRegular(_) => "CATALOGUE_ENTRY_UNSAFE",
            Self::TooLarge => "CATALOGUE_TOO_LARGE",
            Self::InvalidJson(_) => "CATALOGUE_JSON_INVALID",
            Self::Verification(_) => "CATALOGUE_SIGNATURE_INVALID",
            Self::DuplicateModel(_) => "CATALOGUE_DUPLICATE_MODEL",
            Self::InstalledModelDropped(_) => "CATALOGUE_INSTALLED_MODEL_DROPPED",
            Self::InstalledModelChanged(_) => "CATALOGUE_INSTALLED_MODEL_CHANGED",
            Self::ModelInUse(_) => "CATALOGUE_MODEL_IN_USE",
            Self::RecoveryRequired => "CATALOGUE_RECOVERY_REQUIRED",
            Self::InstallInProgress => "CATALOGUE_INSTALL_IN_PROGRESS",
            Self::Promotion(_) => "CATALOGUE_PROMOTION_FAILED",
            Self::Persistence(_) => "CATALOGUE_PERSISTENCE_FAILED",
        }
    }

    fn status(&self) -> StatusCode {
        match self {
            Self::Unavailable => StatusCode::SERVICE_UNAVAILABLE,
            Self::Persistence(_) | Self::Promotion(_) => StatusCode::INTERNAL_SERVER_ERROR,
            _ => StatusCode::UNPROCESSABLE_ENTITY,
        }
    }

    pub(super) fn envelope(&self) -> (StatusCode, Json<Value>) {
        (
            self.status(),
            Json(json!({
                "error": {
                    "code": self.code(),
                    "message": self.to_string(),
                    "request_id": crate::route::current_request_id(),
                }
            })),
        )
    }
}

pub(super) struct VerifiedCandidate {
    pub(super) raw: Vec<u8>,
    pub(super) digest: String,
    pub(super) key_id: String,
    pub(super) inventory: Arc<ModelInventory>,
}

#[derive(Debug, Clone)]
pub(super) struct InstalledModel {
    pub(super) id: String,
    pub(super) recipe_revision: String,
    pub(super) source_revision: String,
}

pub struct CatalogueRefreshService {
    pub(super) catalogue_path: PathBuf,
    pub(super) root: Arc<CatalogueRoot>,
    pub(super) models: Arc<LiveModelInventory>,
    pub(super) database: Arc<parking_lot::Mutex<rusqlite::Connection>>,
    pub(super) promotion_lock: parking_lot::Mutex<()>,
}

impl CatalogueRefreshService {
    pub fn new(
        catalogue_path: impl Into<PathBuf>,
        root: CatalogueRoot,
        models: Arc<LiveModelInventory>,
        database: Arc<parking_lot::Mutex<rusqlite::Connection>>,
    ) -> Result<Self, CatalogueRefreshError> {
        let catalogue_path = catalogue_path.into();
        validate_parent(&catalogue_path)?;
        validate_regular_if_present(&catalogue_path)?;
        validate_regular_if_present(&previous_path(&catalogue_path))?;
        Ok(Self {
            catalogue_path,
            root: Arc::new(root),
            models,
            database,
            promotion_lock: parking_lot::Mutex::new(()),
        })
    }

    /// Reverify recipe authority before accepting delegation for unattended loading.
    pub(crate) fn verify_recipe(
        &self,
        recipe: &spark_models::ModelRecipe,
    ) -> Result<(), CatalogueRefreshError> {
        self.root
            .verify_recipe(recipe)
            .map_err(|error| CatalogueRefreshError::Verification(error.to_string()))
    }

    pub(super) fn verify_candidate(
        &self,
        candidate_json: &str,
    ) -> Result<VerifiedCandidate, CatalogueRefreshError> {
        let raw = candidate_json.as_bytes();
        if raw.len() > MAX_CATALOGUE_BYTES {
            return Err(CatalogueRefreshError::TooLarge);
        }
        let catalogue: SignedCatalogue = serde_json::from_slice(raw)
            .map_err(|error| CatalogueRefreshError::InvalidJson(error.to_string()))?;
        catalogue
            .verify(&self.root)
            .map_err(|error| CatalogueRefreshError::Verification(error.to_string()))?;
        let key_id = catalogue.signature.key_id.clone();
        let recipes = catalogue
            .verified_recipes()
            .map_err(|error| CatalogueRefreshError::Verification(error.to_string()))?;
        let mut ids = HashSet::new();
        for recipe in recipes {
            if !ids.insert(recipe.id().to_owned()) {
                return Err(CatalogueRefreshError::DuplicateModel(
                    recipe.id().to_owned(),
                ));
            }
        }
        Ok(VerifiedCandidate {
            raw: raw.to_vec(),
            digest: hex::encode(Sha256::digest(raw)),
            key_id,
            inventory: Arc::new(ModelInventory {
                recipes: recipes.to_vec(),
                allow_unverified_import: self.models.snapshot().allow_unverified_import,
            }),
        })
    }

    fn installed_models(
        connection: &rusqlite::Connection,
    ) -> Result<Vec<InstalledModel>, CatalogueRefreshError> {
        let mut statement = connection
            .prepare(
                "SELECT id, recipe_revision, source_revision FROM models WHERE install_state = 'installed' ORDER BY id",
            )
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
        statement
            .query_map([], |row| {
                Ok(InstalledModel {
                    id: row.get(0)?,
                    recipe_revision: row.get(1)?,
                    source_revision: row.get(2)?,
                })
            })
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))
    }

    pub(super) fn check_installed_models(
        &self,
        candidate: &VerifiedCandidate,
        connection: &rusqlite::Connection,
    ) -> Result<(), CatalogueRefreshError> {
        let installing = connection
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM operations
                     WHERE kind = 'model.install'
                       AND state IN ('queued', 'running', 'cancelling')
                )",
                [],
                |row| row.get::<_, bool>(0),
            )
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
        if installing {
            return Err(CatalogueRefreshError::InstallInProgress);
        }
        let candidate_by_id: HashMap<_, _> = candidate
            .inventory
            .recipes
            .iter()
            .map(|recipe| (recipe.id(), recipe))
            .collect();
        let current = self.models.snapshot();
        for installed in Self::installed_models(connection)? {
            let Some(candidate_recipe) = candidate_by_id.get(installed.id.as_str()) else {
                return Err(CatalogueRefreshError::InstalledModelDropped(installed.id));
            };
            let Some(current_recipe) = current.recipe(&installed.id) else {
                return Err(CatalogueRefreshError::InstalledModelChanged(installed.id));
            };
            // Use the verified previous snapshot to recover installed provenance after promotion preceded database commit.
            let previous;
            // Older installers retained the original revision marker; matching every signed limit establishes a metadata-only lag.
            let limits_match_current = current_recipe.source.revision == installed.source_revision
                && check_profile_provenance(connection, current_recipe, current_recipe).is_ok();
            let installed_recipe = if current_recipe.metadata.revision == installed.recipe_revision
                || limits_match_current
            {
                current_recipe
            } else {
                // Preserve previous signed evidence while replaying the current snapshot into the database.
                if self.current_digest()?.as_deref() != Some(candidate.digest.as_str()) {
                    return Err(CatalogueRefreshError::RecoveryRequired);
                }
                previous = safe_load_catalogue(&previous_path(&self.catalogue_path), &self.root)?;
                previous
                    .recipes
                    .iter()
                    .find(|recipe| {
                        recipe.id() == installed.id
                            && recipe.metadata.revision == installed.recipe_revision
                    })
                    .ok_or_else(|| {
                        CatalogueRefreshError::InstalledModelChanged(installed.id.clone())
                    })?
            };
            if installed_recipe.source.revision != installed.source_revision
                || !compatible_profile_update(installed_recipe, candidate_recipe)
            {
                return Err(CatalogueRefreshError::InstalledModelChanged(installed.id));
            }
            check_profile_provenance(connection, installed_recipe, candidate_recipe)?;
            if installed_recipe != *candidate_recipe {
                let in_use: bool = connection.query_row(
                    "SELECT EXISTS(SELECT 1 FROM operations WHERE (resource_id = ?1
                        OR (kind = 'workload.adopt' AND json_extract(input_json, '$.model_id') = ?1))
                        AND kind IN ('model.load', 'workload.adopt', 'model.remove')
                        AND state IN ('queued', 'running', 'cancelling'))
                     OR EXISTS(SELECT 1 FROM cluster_launches WHERE recipe_id = ?1
                        AND state IN ('preparing', 'running', 'degraded', 'stopping'))",
                    [&installed.id], |row| row.get(0),
                ).map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
                if in_use {
                    return Err(CatalogueRefreshError::ModelInUse(installed.id));
                }
            }
        }
        Ok(())
    }

    pub(super) fn current_digest(&self) -> Result<Option<String>, CatalogueRefreshError> {
        match safe_read(&self.catalogue_path, MAX_CATALOGUE_BYTES)? {
            Some(bytes) => Ok(Some(hex::encode(Sha256::digest(bytes)))),
            None => Ok(None),
        }
    }

    pub fn status(&self) -> Result<Value, CatalogueRefreshError> {
        let _promotion = self.promotion_lock.lock();
        validate_regular_if_present(&self.catalogue_path)?;
        let bytes = safe_read(&self.catalogue_path, MAX_CATALOGUE_BYTES)?
            .ok_or(CatalogueRefreshError::Unavailable)?;
        let catalogue: SignedCatalogue = serde_json::from_slice(&bytes)
            .map_err(|error| CatalogueRefreshError::InvalidJson(error.to_string()))?;
        catalogue
            .verify(&self.root)
            .map_err(|error| CatalogueRefreshError::Verification(error.to_string()))?;
        let previous = previous_path(&self.catalogue_path);
        validate_regular_if_present(&previous)?;
        let last_refreshed_at = self
            .database
            .lock()
            .query_row(
                "SELECT last_refreshed_at FROM catalogue_refresh_state WHERE singleton = 1",
                [],
                |row| row.get::<_, String>(0),
            )
            .ok();
        Ok(json!({
            "source": "device_local_signed_snapshot",
            "refresh_available": true,
            "recipe_count": catalogue.recipes.len(),
            "current_digest": hex::encode(Sha256::digest(&bytes)),
            "signature_key_id": catalogue.signature.key_id,
            "previous_snapshot_available": previous.exists(),
            "last_refreshed_at": last_refreshed_at,
            "active_engine_unaffected": true,
        }))
    }

    pub(super) fn promote(
        &self,
        candidate_json: &str,
        operation_id: uuid::Uuid,
        lease: &OperationLease,
    ) -> Result<Value, CatalogueRefreshError> {
        let _promotion = self.promotion_lock.lock();
        let _ = lease.set_stage("validating_signature", Some(0.15));
        let candidate = self.verify_candidate(candidate_json)?;
        let _ = lease.set_stage("checking_installed_models", Some(0.30));
        self.check_installed_models(&candidate, &self.database.lock())?;

        let previous = previous_path(&self.catalogue_path);
        validate_parent(&self.catalogue_path)?;
        validate_regular_if_present(&self.catalogue_path)?;
        validate_regular_if_present(&previous)?;
        let current_digest = self.current_digest()?;
        let already_current = current_digest.as_deref() == Some(candidate.digest.as_str());
        let mut moved_current = false;
        if !already_current {
            let _ = lease.set_stage("staging_snapshot", Some(0.50));
            let temporary = temporary_path(&self.catalogue_path, operation_id)?;
            stage_candidate(&temporary, &candidate.raw)?;
            let _ = lease.set_stage("promoting_snapshot", Some(0.70));
            if self.catalogue_path.exists() {
                fs::rename(&self.catalogue_path, &previous)
                    .map_err(|error| CatalogueRefreshError::Promotion(error.to_string()))?;
                moved_current = true;
            }
            if let Err(error) = fs::rename(&temporary, &self.catalogue_path) {
                let _ = fs::remove_file(&temporary);
                let primary = CatalogueRefreshError::Promotion(error.to_string());
                return Err(rollback_or(
                    primary,
                    &self.catalogue_path,
                    &previous,
                    moved_current,
                ));
            }
            if let Err(error) = sync_directory(
                self.catalogue_path
                    .parent()
                    .ok_or_else(|| CatalogueRefreshError::Promotion("missing parent".into()))?,
            ) {
                return Err(rollback_or(
                    error,
                    &self.catalogue_path,
                    &previous,
                    moved_current,
                ));
            }
            if let Err(error) = safe_load_catalogue(&self.catalogue_path, &self.root) {
                return Err(rollback_or(
                    error,
                    &self.catalogue_path,
                    &previous,
                    moved_current,
                ));
            }
        }

        let _ = lease.set_stage("materialising_catalogue", Some(0.85));
        let mut connection = self.database.lock();
        let transaction = connection
            .transaction()
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
        if let Err(error) = self.check_installed_models(&candidate, &transaction) {
            if !already_current {
                return Err(rollback_or(
                    error,
                    &self.catalogue_path,
                    &previous,
                    moved_current,
                ));
            }
            return Err(error);
        }
        let materialise = (|| -> Result<(), CatalogueRefreshError> {
            for recipe in &candidate.inventory.recipes {
                crate::store::upsert_catalogue_model(&transaction, recipe)
                    .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
                update_installed_profiles(&transaction, recipe)?;
                // Advance signed recipe metadata without changing installed files or measured safety history.
                transaction.execute(
                    "UPDATE models SET recipe_revision = ?2 WHERE id = ?1 AND install_state = 'installed'",
                    rusqlite::params![recipe.id(), recipe.metadata.revision],
                ).map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
            }
            transaction
                .execute(
                    "INSERT INTO catalogue_refresh_state
                        (singleton, current_digest, signature_key_id, recipe_count,
                         previous_snapshot_available, last_refreshed_at, last_operation_id)
                     VALUES (1, ?1, ?2, ?3, ?4, strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?5)
                     ON CONFLICT(singleton) DO UPDATE SET
                        current_digest = excluded.current_digest,
                        signature_key_id = excluded.signature_key_id,
                        recipe_count = excluded.recipe_count,
                        previous_snapshot_available = excluded.previous_snapshot_available,
                        last_refreshed_at = excluded.last_refreshed_at,
                        last_operation_id = excluded.last_operation_id",
                    rusqlite::params![
                        candidate.digest,
                        candidate.key_id,
                        candidate.inventory.recipes.len() as i64,
                        previous.exists(),
                        operation_id.to_string(),
                    ],
                )
                .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
            transaction
                .commit()
                .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))
        })();
        if let Err(error) = materialise {
            if !already_current {
                return Err(rollback_or(
                    error,
                    &self.catalogue_path,
                    &previous,
                    moved_current,
                ));
            }
            return Err(error);
        }
        self.models.replace(candidate.inventory.clone());
        drop(connection);
        let _ = lease.set_stage("catalogue_ready", Some(1.0));
        Ok(json!({
            "catalogue": "ready",
            "current_digest": candidate.digest,
            "signature_key_id": candidate.key_id,
            "recipe_count": candidate.inventory.recipes.len(),
            "previous_snapshot_available": previous.exists(),
            "already_current": already_current,
            "active_engine_unaffected": true,
        }))
    }
}

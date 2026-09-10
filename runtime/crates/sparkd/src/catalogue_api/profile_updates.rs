use super::*;

/// Accept signed preset corrections while preserving model artifacts, execution policy and the system reserve.
pub(super) fn compatible_profile_update(
    current: &spark_models::ModelRecipe,
    candidate: &spark_models::ModelRecipe,
) -> bool {
    let unique: HashSet<_> = candidate
        .profiles
        .iter()
        .map(|profile| &profile.id)
        .collect();
    if unique.len() != candidate.profiles.len()
        || current.memory.minimum_system_reserve_bytes
            != candidate.memory.minimum_system_reserve_bytes
    {
        return false;
    }
    let mut unchanged = candidate.clone();
    unchanged.profiles = current.profiles.clone();
    unchanged.memory = current.memory.clone();
    unchanged.metadata.revision = current.metadata.revision.clone();
    unchanged.metadata.description = current.metadata.description.clone();
    unchanged.signature = current.signature.clone();
    unchanged == *current
        && (candidate == current || candidate.metadata.revision != current.metadata.revision)
}

/// Refuse to overwrite locally modified settings, including when replaying an interrupted promotion.
pub(super) fn check_profile_provenance(
    connection: &rusqlite::Connection,
    current: &spark_models::ModelRecipe,
    candidate: &spark_models::ModelRecipe,
) -> Result<(), CatalogueRefreshError> {
    for profile in &candidate.profiles {
        if current
            .profiles
            .iter()
            .any(|previous| previous.id == profile.id)
        {
            continue;
        }
        let exists: bool = connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM model_profiles WHERE model_id = ?1 AND profile_id = ?2)",
            rusqlite::params![current.id(), profile.id], |row| row.get(0),
        ).map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
        if exists {
            return Err(CatalogueRefreshError::InstalledModelChanged(format!(
                "{} / {} would replace a custom preset",
                current.id(),
                profile.id
            )));
        }
    }
    for profile in &current.profiles {
        let matches: bool = connection
            .query_row(
                "SELECT context_length = ?3 AND max_sequences = ?4 AND max_batched_tokens = ?5
                    AND gpu_memory_utilisation = ?6 AND expected_peak_bytes = ?7
             FROM model_profiles WHERE model_id = ?1 AND profile_id = ?2",
                rusqlite::params![
                    current.id(),
                    profile.id,
                    profile.max_model_length,
                    profile.max_sequences,
                    profile.max_batched_tokens,
                    profile.gpu_memory_utilisation,
                    profile.expected_peak_bytes
                ],
                |row| row.get(0),
            )
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
        if !matches {
            return Err(CatalogueRefreshError::InstalledModelChanged(format!(
                "{} / {} has custom preset settings",
                current.id(),
                profile.id
            )));
        }
    }
    Ok(())
}

/// Update only reviewed signed limits; measured peaks, unsafe flags and download provenance survive.
pub(super) fn update_installed_profiles(
    connection: &rusqlite::Connection,
    recipe: &spark_models::ModelRecipe,
) -> Result<(), CatalogueRefreshError> {
    for profile in &recipe.profiles {
        connection
            .execute(
                "UPDATE model_profiles SET context_length = ?3, max_sequences = ?4,
                max_batched_tokens = ?5, gpu_memory_utilisation = ?6, expected_peak_bytes = ?7
             WHERE model_id = ?1 AND profile_id = ?2
               AND EXISTS(SELECT 1 FROM models WHERE id = ?1 AND install_state = 'installed')",
                rusqlite::params![
                    recipe.id(),
                    profile.id,
                    profile.max_model_length,
                    profile.max_sequences,
                    profile.max_batched_tokens,
                    profile.gpu_memory_utilisation,
                    profile.expected_peak_bytes
                ],
            )
            .map_err(|error| CatalogueRefreshError::Persistence(error.to_string()))?;
    }
    Ok(())
}

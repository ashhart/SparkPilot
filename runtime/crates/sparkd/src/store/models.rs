use super::{Connection, OptionalExtension, StoreError, now, params};

// Persist catalogue model and profile inventory.

/// Mirror recipe profiles and preserve model install state until downloads complete.
pub fn upsert_catalogue_model(
    conn: &Connection,
    recipe: &spark_models::ModelRecipe,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO models
            (id, recipe_revision, recipe_digest, source_revision, display_name,
             install_state, installed_at, manifest_path, total_bytes,
             measured_peak_bytes, last_used_at, failure_code, metadata_json)
         VALUES (?1, ?2, ?3, ?4, ?5, 'available', NULL, NULL, NULL, NULL, NULL, NULL, '{}')
         ON CONFLICT(id) DO UPDATE SET
            recipe_revision = excluded.recipe_revision,
            source_revision = excluded.source_revision,
            display_name = excluded.display_name
         WHERE models.install_state != 'installed'",
        params![
            recipe.id(),
            recipe.metadata.revision,
            "pending", // pinned digest recorded at download
            recipe.source.revision,
            recipe.metadata.display_name,
        ],
    )?;
    for profile in &recipe.profiles {
        conn.execute(
            "INSERT INTO model_profiles
                (model_id, profile_id, context_length, max_sequences, max_batched_tokens,
                 gpu_memory_utilisation, expected_peak_bytes, measured_peak_bytes,
                 safe, last_failure_code, last_measured_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, 1, NULL, NULL)
             ON CONFLICT(model_id, profile_id) DO UPDATE SET
                context_length = excluded.context_length,
                max_sequences = excluded.max_sequences,
                max_batched_tokens = excluded.max_batched_tokens,
                gpu_memory_utilisation = excluded.gpu_memory_utilisation,
                expected_peak_bytes = excluded.expected_peak_bytes
             WHERE (SELECT install_state FROM models WHERE id = excluded.model_id) != 'installed'",
            params![
                recipe.id(),
                profile.id,
                profile.max_model_length as i64,
                profile.max_sequences as i64,
                profile.max_batched_tokens as i64,
                profile.gpu_memory_utilisation,
                profile.expected_peak_bytes as i64,
            ],
        )?;
    }
    Ok(())
}

/// Inventory row shape for the catalogue view.
#[derive(Debug, Clone)]
pub struct ModelInventoryRow {
    pub id: String,
    pub recipe_revision: String,
    pub source_revision: String,
    pub display_name: String,
    pub install_state: String,
    pub total_bytes: Option<i64>,
}

pub fn list_model_rows(conn: &Connection) -> Result<Vec<ModelInventoryRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, recipe_revision, source_revision, display_name, install_state, total_bytes
           FROM models ORDER BY display_name",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(ModelInventoryRow {
                id: r.get(0)?,
                recipe_revision: r.get(1)?,
                source_revision: r.get(2)?,
                display_name: r.get(3)?,
                install_state: r.get(4)?,
                total_bytes: r.get(5)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn model_row(conn: &Connection, id: &str) -> Result<Option<ModelInventoryRow>, StoreError> {
    conn.query_row(
        "SELECT id, recipe_revision, source_revision, display_name, install_state, total_bytes
           FROM models WHERE id = ?1",
        params![id],
        |r| {
            Ok(ModelInventoryRow {
                id: r.get(0)?,
                recipe_revision: r.get(1)?,
                source_revision: r.get(2)?,
                display_name: r.get(3)?,
                install_state: r.get(4)?,
                total_bytes: r.get(5)?,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

/// Mark only noninstalled rows unverified and report whether changed, preserving installed models on import-id collisions.
pub fn mark_model_unverified(conn: &Connection, id: &str) -> Result<bool, StoreError> {
    let changed = conn.execute(
        "UPDATE models SET install_state = 'unverified'
          WHERE id = ?1 AND install_state != 'installed'",
        params![id],
    )?;
    Ok(changed > 0)
}

/// Remove a model and its profiles (cascades via FK).
pub fn remove_model_row(conn: &Connection, id: &str) -> Result<(), StoreError> {
    let changed = conn.execute("DELETE FROM models WHERE id = ?1", params![id])?;
    if changed == 0 {
        return Err(StoreError::NotFound("model"));
    }
    Ok(())
}

// Persist model files and download state.

pub fn upsert_model_file(
    conn: &Connection,
    model_id: &str,
    file: &spark_models::recipe::RemoteFile,
) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO model_files
            (model_id, relative_path, size_bytes, sha256, download_state,
             completed_bytes, etag, updated_at)
         VALUES (?1, ?2, ?3, ?4, 'pending', 0, NULL, ?5)
         ON CONFLICT(model_id, relative_path) DO NOTHING",
        rusqlite::params![
            model_id,
            file.relative_path,
            file.size_bytes as i64,
            file.sha256,
            now()
        ],
    )?;
    Ok(())
}

pub fn mark_model_available(conn: &Connection, model_id: &str) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE models SET install_state = 'available' WHERE id = ?1",
        rusqlite::params![model_id],
    )?;
    Ok(())
}

pub fn mark_model_downloading(conn: &Connection, model_id: &str) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE models SET install_state = 'downloading' WHERE id = ?1",
        rusqlite::params![model_id],
    )?;
    Ok(())
}

pub fn mark_model_installed(
    conn: &Connection,
    model_id: &str,
    total_bytes: u64,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE models SET install_state = 'installed', installed_at = ?1, total_bytes = ?2
          WHERE id = ?3",
        rusqlite::params![now(), total_bytes as i64, model_id],
    )?;
    Ok(())
}

pub fn mark_model_download_progress(
    conn: &Connection,
    model_id: &str,
    relative_path: &str,
    completed_bytes: u64,
    downloading: bool,
) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE model_files SET completed_bytes = ?1, download_state = ?2, updated_at = ?3
          WHERE model_id = ?4 AND relative_path = ?5",
        rusqlite::params![
            completed_bytes as i64,
            if downloading {
                "downloading"
            } else {
                "complete"
            },
            now(),
            model_id,
            relative_path
        ],
    )?;
    Ok(())
}

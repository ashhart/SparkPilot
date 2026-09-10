use super::*;

pub(super) fn capabilities_value(recipe: &ModelRecipe) -> Value {
    json!({
        "chat": recipe.capabilities.chat,
        "reasoning": recipe.capabilities.reasoning,
        "tool_calling": recipe.capabilities.tool_calling,
        "guided_generation": recipe.capabilities.guided_generation,
        "vision": recipe.capabilities.vision,
        "embeddings": recipe.capabilities.embeddings,
    })
}

/// Project stored safety and peak measurements; profiles without stored evidence remain unmeasured rather than inventing a peak.
pub(super) fn profiles_value(conn: &rusqlite::Connection, recipe: &ModelRecipe) -> Value {
    let environment = crate::guard::recipe_environment(recipe);
    Value::Array(
        recipe
            .profiles
            .iter()
            .map(|p| {
                let unsafe_profile =
                    crate::guard::profile_is_unsafe(conn, recipe.id(), &p.id).unwrap_or(false);
                let measured = crate::guard::measured_peak(conn, recipe.id(), &p.id, &environment)
                    .ok()
                    .flatten();
                let configured = conn.query_row(
                    "SELECT p.idle_policy, t.timeout_seconds FROM model_idle_policies p
                     LEFT JOIN model_idle_timeouts t ON p.model_id = t.model_id AND p.profile_id = t.profile_id
                     WHERE p.model_id = ?1 AND p.profile_id = ?2",
                    rusqlite::params![recipe.id(), p.id],
                    |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<u64>>(1)?)),
                ).ok();
                let mut value = json!({
                    "id": p.id,
                    "display_name": p.display_name,
                    "max_model_length": p.max_model_length,
                    "max_sequences": p.max_sequences,
                    "expected_peak_bytes": p.expected_peak_bytes,
                    "measured_peak_bytes": measured,
                    "safe": !unsafe_profile,
                    "idle_policy": configured.as_ref().map(|c| c.0.as_str()).unwrap_or(&p.idle_policy),
                    "supports_custom_idle_timeout": recipe.engine.recipe.starts_with("vllm-"),
                    "supported_idle_policies": supported_idle_policies(recipe, &p.idle_policy),
                });
                if let Some(seconds) = configured.and_then(|c| c.1) {
                    value["idle_timeout_seconds"] = json!(seconds);
                }
                value
            })
            .collect(),
    )
}

pub(crate) fn supported_idle_policies(recipe: &ModelRecipe, configured: &str) -> Vec<String> {
    let mut policies = if recipe.engine.recipe.starts_with("vllm-") {
        vec![
            "keep_ready".to_owned(),
            "unload_after_15m".to_owned(),
            "unload_after_30m".to_owned(),
            "unload_after_60m".to_owned(),
            "manual_only".to_owned(),
        ]
    } else {
        vec!["manual_only".to_owned()]
    };
    if !policies.iter().any(|policy| policy == configured) {
        policies.insert(0, configured.to_owned());
    }
    policies
}

pub(super) fn fit_value(fit: FitState) -> &'static str {
    match fit {
        FitState::Ready => "ready",
        FitState::Fits => "fits",
        FitState::FitsAfterUnload => "fits_after_unload",
        FitState::SmallerProfileRequired => "smaller_profile_required",
        FitState::ClusterRequired => "cluster_required",
        FitState::Incompatible => "incompatible",
        FitState::Unknown => "unknown",
    }
}

/// Include reclaimable engine memory in fit estimates and report unknown when no engine evidence is available.
#[allow(clippy::too_many_arguments)]
pub(super) fn present_fit(
    conn: &rusqlite::Connection,
    recipe: &ModelRecipe,
    installed: bool,
    available_bytes: u64,
    reclaimable_bytes: u64,
    cluster_available: bool,
    residency_known: bool,
    system_reserve_bytes: u64,
) -> FitState {
    if !residency_known {
        return FitState::Unknown;
    }
    // Use admission's conservative budget while keeping signed declarations separate from observed whole-engine measurements.
    let mut measured_recipe = recipe.clone();
    let environment = crate::guard::recipe_environment(recipe);
    for profile in &mut measured_recipe.profiles {
        let measured =
            match crate::guard::measured_peak(conn, recipe.id(), &profile.id, &environment) {
                Ok(measured) => measured,
                Err(_) => return FitState::Unknown,
            };
        profile.expected_peak_bytes = profile.expected_peak_bytes.max(measured.unwrap_or(0));
    }
    compute_fit(
        &measured_recipe,
        installed,
        available_bytes,
        system_reserve_bytes,
        reclaimable_bytes,
        cluster_available,
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn model_view(
    conn: &rusqlite::Connection,
    recipe: &ModelRecipe,
    row: &store::ModelInventoryRow,
    available_bytes: u64,
    reclaimable_bytes: u64,
    cluster_available: bool,
    residency_known: bool,
    system_reserve_bytes: u64,
) -> Value {
    json!({
        "id": recipe.id(),
        "display_name": recipe.metadata.display_name,
        "description": recipe.metadata.description,
        "recipe_revision": recipe.metadata.revision,
        "source_revision": recipe.source.revision,
        "source_provider": recipe.source.provider,
        "gated": recipe.source.gated,
        // Distinguish the model publisher from the author of its serving recipe.
        "publisher": recipe.metadata.publisher,
        "publisher_url": recipe.metadata.publisher_url,
        "licence_url": recipe.source.licence_url,
        "recipe_source": recipe.metadata.recipe_source.as_ref().map(|source| {
            json!({
                "name": source.name,
                "url": source.url,
                "revision": source.revision,
            })
        }),
        "install_state": row.install_state,
        "total_bytes": row.total_bytes,
        "capabilities": capabilities_value(recipe),
        "fit": fit_value(present_fit(
            conn,
            recipe,
            row.install_state == "installed",
            available_bytes,
            reclaimable_bytes,
            cluster_available,
            residency_known,
            system_reserve_bytes,
        )),
        "profiles": profiles_value(conn, recipe),
    })
}

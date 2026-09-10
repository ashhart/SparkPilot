use super::*;

/// Called under EngineManager's core lock for ordinary and pool admission.
pub(crate) fn engine_capacity_charge(conn: &Connection) -> Result<Option<u32>, rusqlite::Error> {
    let installed: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='inference_pool_policies')",
        [],
        |r| r.get(0),
    )?;
    if !installed {
        return Ok(None);
    }
    let enabled: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM inference_pool_policies)",
        [],
        |r| r.get(0),
    )?;
    if !enabled {
        return Ok(None);
    }
    conn.query_row(
        &format!("SELECT count(*) FROM inference_reservations WHERE state IN {CHARGED} AND capacity_released=0"),
        [],
        |r| r.get(0),
    )
    .map(Some)
}

/// §31.9: report the durable work one engine instance still owes so idle reclamation cannot destroy it.
pub(crate) fn durable_work_outstanding(
    conn: &Connection,
    instance: Uuid,
) -> Result<bool, rusqlite::Error> {
    let installed: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='inference_reservations')",
        [],
        |r| r.get(0),
    )?;
    if !installed {
        return Ok(false);
    }
    conn.query_row(
        &format!(
            "SELECT EXISTS(SELECT 1 FROM inference_reservations
              WHERE engine_instance_id=?1 AND capacity_released=0 AND state IN {CHARGED})"
        ),
        [instance.to_string()],
        |r| r.get(0),
    )
}

/// Release capacity only after positive managed-container stop evidence; retain unknown receipts to prevent duplicate execution.
pub(crate) fn release_stopped_instance(
    conn: &Connection,
    instance: Uuid,
) -> Result<(), rusqlite::Error> {
    let installed: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='inference_reservations')",
        [],
        |r| r.get(0),
    )?;
    if installed {
        conn.execute("UPDATE inference_reservations SET capacity_released=1,state=CASE WHEN state='reserved' THEN 'cancelled' ELSE 'outcome_unknown' END,reason=CASE WHEN state='reserved' THEN 'not_dispatched' ELSE 'engine_stopped_outcome_unknown' END WHERE engine_instance_id=?1 AND capacity_released=0 AND state IN ('reserved','accepted','cancel_requested','outcome_unknown')", [instance.to_string()])?;
    }
    Ok(())
}

pub fn deployment(
    instance: &EngineInstance,
    runtime_version: &str,
) -> Result<DeploymentIdentity, PoolError> {
    let recipe = &instance.recipe;
    if instance.external_workload_id.is_some()
        || recipe.source.trust_remote_code
        || recipe.signature.algorithm != "ed25519"
        || recipe.signature.value.is_empty()
        || !matches!(recipe.source.revision.len(), 40 | 64)
        || !recipe
            .source
            .revision
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
        || !recipe.capabilities.chat
        || recipe.security.allow_network_during_inference
    {
        return refuse("POOL_DEPLOYMENT_IDENTITY_UNPROVEN");
    }
    let recipe_sha256 = sha256_hex(&serde_json::to_vec(recipe)?);
    // Bind weights, tokenizer, templates, quantization and adapters through the immutable revision, plus the engine image.
    let model_identity = digest(
        &json!({"source":recipe.source,"engine_image":recipe.engine.image,"tokenizer_mode":recipe.engine.tokenizer_mode}),
    )?;
    let deployment_id = digest(
        &json!({"model_identity":model_identity,"recipe":recipe_sha256,"profile":instance.profile,"runtime":runtime_version,"generation":instance.instance_id}),
    )?;
    Ok(DeploymentIdentity {
        deployment_id,
        model_identity,
        model_id: instance.model_id.clone(),
        source_repository: recipe.source.repository.clone(),
        source_revision: recipe.source.revision.clone(),
        recipe_sha256,
        profile_id: instance.profile_id.clone(),
        engine_image: recipe.engine.image.clone(),
        runtime_version: runtime_version.into(),
        generation: instance.instance_id,
        context_length: instance.profile.max_model_length,
        max_sequences: instance.profile.max_sequences,
        capabilities: vec!["text_chat".into(), "streaming".into()],
        qualification_id: None,
    })
}

pub(crate) fn check_resource_state(
    state: &AppState,
    instance: &EngineInstance,
) -> Result<(), PoolError> {
    let memory = state.telemetry.system();
    if !matches!(
        memory.memory_pressure,
        spark_telemetry::MemoryPressure::Normal
    ) || state
        .guard
        .as_ref()
        .is_some_and(|g| g.reading().state != spark_telemetry::PressureState::Normal)
        || memory.unified_memory_available_bytes
            < instance.recipe.memory.minimum_system_reserve_bytes
        || memory
            .temperature_celsius
            .is_some_and(|v| !v.is_finite() || v >= 85.0)
    {
        return refuse("POOL_RESOURCE_PRESSURE");
    }
    Ok(())
}

pub fn validate_execution_body(
    body: &[u8],
    r: &AdmissionReservation,
    served: &str,
    model: &str,
) -> Result<(), PoolError> {
    if body.len() > MAX_REQUEST_BYTES {
        return refuse("POOL_REQUEST_INVALID");
    }
    let v: Value = serde_json::from_slice(body)?;
    let Some(obj) = v.as_object() else {
        return refuse("POOL_REQUEST_INVALID");
    };
    if obj.keys().any(|k| {
        !matches!(
            k.as_str(),
            "model" | "messages" | "max_tokens" | "stream" | "temperature" | "top_p"
        )
    }) {
        return refuse("POOL_CAPABILITY_UNSUPPORTED");
    }
    if !v["model"]
        .as_str()
        .is_some_and(|s| s == served || s == model)
        || v["max_tokens"].as_u64() != Some(u64::from(r.output_budget))
    {
        return refuse("POOL_REQUEST_INVALID");
    }
    if v.get("stream").is_some_and(|s| !s.is_boolean()) {
        return refuse("POOL_REQUEST_INVALID");
    }
    let Some(messages) = v["messages"].as_array() else {
        return refuse("POOL_REQUEST_INVALID");
    };
    if messages.is_empty() || messages.len() > 128 {
        return refuse("POOL_REQUEST_INVALID");
    }
    let mut conservative = 0u64;
    for m in messages {
        let Some(o) = m.as_object() else {
            return refuse("POOL_REQUEST_INVALID");
        };
        if o.keys().any(|k| !matches!(k.as_str(), "role" | "content"))
            || !m["role"]
                .as_str()
                .is_some_and(|s| matches!(s, "system" | "user" | "assistant"))
        {
            return refuse("POOL_CAPABILITY_UNSUPPORTED");
        }
        let Some(content) = m["content"].as_str() else {
            return refuse("POOL_CAPABILITY_UNSUPPORTED");
        };
        conservative = conservative.saturating_add(content.len() as u64 + 256);
    }
    if conservative > r.context_budget {
        return refuse("POOL_CONTEXT_BUDGET_EXCEEDED");
    }
    for (key, max) in [("temperature", 2.0), ("top_p", 1.0)] {
        if v.get(key).is_some_and(|n| {
            n.as_f64()
                .is_none_or(|f| !f.is_finite() || f < 0.0 || f > max)
        }) {
            return refuse("POOL_REQUEST_INVALID");
        }
    }
    Ok(())
}

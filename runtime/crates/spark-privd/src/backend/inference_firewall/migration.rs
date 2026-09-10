use super::*;

// Old containers retain Docker's external resolver until they are recreated.
pub(super) fn stop_legacy(backend: &DockerBackend, network: &Value) -> Result<(), BackendError> {
    let members = network["Containers"]
        .as_object()
        .ok_or_else(|| BackendError::Failure("missing inference network membership".into()))?;
    for (id, member) in members {
        if id.len() != 64 || !id.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err(BackendError::Failure(
                "invalid inference container identity".into(),
            ));
        }
        let name = member["Name"].as_str().unwrap_or("");
        let model = name
            .strip_prefix("spark-model-")
            .is_some_and(|v| uuid::Uuid::parse_str(v).is_ok());
        let kokoro = name == crate::kokoro::CONTAINER;
        let output = backend.run_appliance(
            &backend.docker_bin,
            vec!["inspect".into(), id.clone()],
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(
                "cannot inspect legacy inference container".into(),
            ));
        }
        let values: Vec<Value> = serde_json::from_slice(&output.stdout)
            .map_err(|_| BackendError::Failure("invalid legacy inference inspection".into()))?;
        let value = values
            .first()
            .filter(|_| values.len() == 1)
            .ok_or_else(|| BackendError::Failure("ambiguous legacy inference inspection".into()))?;
        if value["HostConfig"]["Dns"] == json!(["127.0.0.1"]) {
            continue;
        }
        let owned_model = model
            && value["Config"]["User"]
                == format!("{}:{}", backend.service_uid, backend.service_gid)
            && value["Mounts"].as_array().is_some_and(|mounts| {
                mounts.iter().any(|m| {
                    m["Destination"] == "/model"
                        && m["Source"]
                            .as_str()
                            .is_some_and(|p| Path::new(p).starts_with(&backend.models_root))
                })
            });
        let owned_kokoro = kokoro
            && value["Config"]["Labels"]["spark.service"] == "kokoro"
            && value["Config"]["Image"].as_str().is_some_and(|image| {
                image.starts_with("ghcr.io/remsky/kokoro-fastapi-gpu@sha256:")
                    && valid_pinned_image(image)
            });
        if !owned_model && !owned_kokoro {
            return Err(BackendError::Failure(
                "unmanaged container on the reserved inference network needs administrator review"
                    .into(),
            ));
        }
        for args in [
            vec!["update".into(), "--restart=no".into(), id.clone()],
            vec!["stop".into(), "--time=20".into(), id.clone()],
        ] {
            if !backend
                .run_appliance(&backend.docker_bin, args, None)?
                .success()
            {
                return Err(BackendError::Failure(
                    "legacy inference container could not be stopped safely".into(),
                ));
            }
        }
        tracing::warn!(container = %name, "stopped legacy inference container; recreate with protected DNS");
    }
    Ok(())
}

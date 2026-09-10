use super::*;

pub(super) fn probe(
    request_id: uuid::Uuid,
    runtime_unavailable: bool,
    gpu_runtime: Option<bool>,
) -> Result<PrivilegedResponse, BackendError> {
    if runtime_unavailable {
        return Ok(PrivilegedResponse::rejected(
            request_id,
            "runtime_unavailable",
            "no container runtime available",
        ));
    }
    Ok(PrivilegedResponse {
        request_id,
        accepted: true,
        code: "runtime_available".into(),
        message: "fake runtime is available".into(),
        details: serde_json::json!({
            "runtime": "fake",
            "gpu_runtime": gpu_runtime,
        }),
    })
}

pub(super) fn diagnostic(
    request_id: uuid::Uuid,
    source: &LogSource,
    logs: &std::sync::Mutex<HashMap<String, Vec<u8>>>,
) -> Result<PrivilegedResponse, BackendError> {
    let scripted = logs
        .lock()
        .expect("fake diagnostic logs")
        .get(source.name())
        .cloned();
    match scripted {
        // Apply production byte limits to the scripted logs.
        Some(bytes) => Ok(diagnostic_log_response(request_id, *source, &bytes)),
        None => Ok(PrivilegedResponse {
            request_id,
            accepted: false,
            code: "diagnostic_log_unavailable".into(),
            message: "no log was scripted for this source".into(),
            details: serde_json::Value::Null,
        }),
    }
}

pub(super) fn inventory(
    request_id: uuid::Uuid,
    workloads: &std::sync::Mutex<Option<crate::workloads::ObservedWorkloads>>,
) -> Result<PrivilegedResponse, BackendError> {
    let scripted = workloads.lock().expect("fake workload inventory").clone();
    match scripted {
        Some(observed) => Ok(PrivilegedResponse {
            request_id,
            accepted: true,
            code: "workloads_observed".into(),
            message: "fake host workload observation".into(),
            details: serde_json::to_value(&observed).map_err(|error| {
                BackendError::Failure(format!("workload inventory encode: {error}"))
            })?,
        }),
        None => Ok(PrivilegedResponse {
            request_id,
            accepted: false,
            code: "workload_inventory_unavailable".into(),
            message: "the container runtime could not be inspected".into(),
            details: serde_json::Value::Null,
        }),
    }
}

use super::*;

#[derive(Debug)]
pub(super) struct ContainerEvidence {
    pub(super) labels: HashMap<String, String>,
    pub(super) image: String,
    pub(super) running: bool,
    pub(super) status: String,
}

pub(super) fn inspect_container(
    backend: &DockerBackend,
    name: &str,
) -> Result<Option<ContainerEvidence>, BackendError> {
    let output = backend.run_appliance(
        &backend.docker_bin,
        vec![
            "inspect".into(),
            "--format={{json .Config.Labels}}\t{{.Config.Image}}\t{{.State.Running}}\t{{.State.Status}}".into(),
            name.into(),
        ],
        None,
    )?;
    if !output.success() {
        let detail = output.stderr_text().to_ascii_lowercase();
        if detail.contains("no such object") || detail.contains("no such container") {
            return Ok(None);
        }
        return Err(BackendError::Failure(
            "Docker could not inspect an owned cluster container".into(),
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut fields = text.trim().splitn(4, '\t');
    let labels = fields
        .next()
        .and_then(|value| serde_json::from_str(value).ok())
        .ok_or_else(|| BackendError::Failure("cluster container labels are invalid".into()))?;
    let image = fields
        .next()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BackendError::Failure("cluster container image is missing".into()))?
        .to_owned();
    let running = match fields.next() {
        Some("true") => true,
        Some("false") => false,
        _ => {
            return Err(BackendError::Failure(
                "cluster container running state is invalid".into(),
            ));
        }
    };
    let status = fields
        .next()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BackendError::Failure("cluster container status is missing".into()))?
        .to_owned();
    Ok(Some(ContainerEvidence {
        labels,
        image,
        running,
        status,
    }))
}

pub(super) fn spark_labels(labels: &HashMap<String, String>) -> HashMap<String, String> {
    labels
        .iter()
        .filter(|(key, _)| key.starts_with("spark."))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

pub(super) fn require_exact_container(
    evidence: &ContainerEvidence,
    expected_labels: &HashMap<String, String>,
    expected_image: &str,
    context: &str,
) -> Result<(), BackendError> {
    if evidence.image != expected_image || spark_labels(&evidence.labels) != *expected_labels {
        return Err(BackendError::Failure(format!(
            "{context} name is owned by different immutable inputs"
        )));
    }
    Ok(())
}

pub(super) fn append_labels(argv: &mut Vec<String>, labels: &HashMap<String, String>) {
    let mut labels = labels.iter().collect::<Vec<_>>();
    labels.sort_by(|left, right| left.0.cmp(right.0));
    argv.extend(
        labels
            .into_iter()
            .map(|(key, value)| format!("--label={key}={value}")),
    );
}

pub(super) fn remove_container(backend: &DockerBackend, name: &str) -> Result<(), BackendError> {
    let output = backend.run_appliance(
        &backend.docker_bin,
        vec!["rm".into(), "-f".into(), name.into()],
        None,
    )?;
    if output.success() {
        return Ok(());
    }
    let detail = output.stderr_text().to_ascii_lowercase();
    if detail.contains("no such container") || detail.contains("no such object") {
        return Ok(());
    }
    Err(BackendError::Failure(
        "an owned cluster container could not be removed".into(),
    ))
}

pub(super) fn ensure_container(
    backend: &DockerBackend,
    name: &str,
    labels: &HashMap<String, String>,
    image_digest: &str,
    argv: &[String],
) -> Result<bool, BackendError> {
    if let Some(evidence) = inspect_container(backend, name)? {
        require_exact_container(&evidence, labels, image_digest, "cluster launch")?;
        if evidence.running && evidence.status == "running" {
            return Ok(true);
        }
        let output =
            backend.run_appliance(&backend.docker_bin, vec!["start".into(), name.into()], None)?;
        if !output.success() {
            return Err(BackendError::Failure(
                "an exact stopped cluster container could not be restarted".into(),
            ));
        }
        return Ok(true);
    }
    let output = backend.run_appliance(&argv[0], argv[1..].to_vec(), None)?;
    if !output.success() {
        return Err(BackendError::Failure(format!(
            "could not start distributed container: {}",
            bounded_detail(&output.stderr)
        )));
    }
    Ok(false)
}

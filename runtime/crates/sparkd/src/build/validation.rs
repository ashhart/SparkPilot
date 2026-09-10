use super::*;

/// Require the lowercase immutable commit format accepted by fixed build recipes.
pub fn is_sha1_immutable(commit: &str) -> bool {
    commit.len() == 40
        && commit
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

pub fn is_sha256(digest: &str) -> bool {
    digest.len() == 64
        && digest
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

pub(super) fn validate_requirements(requirements: &BuildRequirements) -> Result<(), String> {
    if requirements.platform != "macOS" {
        return Err("BUILD_PLATFORM_UNSUPPORTED".into());
    }
    if requirements.architecture.is_empty() || requirements.architecture.len() > 64 {
        return Err("BUILD_REQUIREMENTS_INVALID".into());
    }
    for value in [
        requirements.minimum_xcode_version.as_deref(),
        requirements.sdk.as_deref(),
        requirements.simulator.as_deref(),
    ]
    .into_iter()
    .flatten()
    {
        if value.is_empty() || value.len() > 200 || value.chars().any(char::is_control) {
            return Err("BUILD_REQUIREMENTS_INVALID".into());
        }
    }
    Ok(())
}

pub(super) fn worker_matches(
    worker: &store::BuildWorkerRow,
    capabilities: &Value,
    required: &BuildRequirements,
) -> bool {
    if required.platform != "macOS"
        || !capabilities
            .get("architectures")
            .and_then(Value::as_array)
            .is_some_and(|values| {
                values
                    .iter()
                    .any(|value| value.as_str() == Some(&required.architecture))
            })
        || required.signing_required
            && capabilities
                .get("signing_available")
                .and_then(Value::as_bool)
                != Some(true)
    {
        return false;
    }
    if let Some(minimum) = required.minimum_xcode_version.as_deref()
        && version_less_than(&worker.xcode_version, minimum)
    {
        return false;
    }
    if let Some(sdk) = required.sdk.as_deref()
        && !capabilities
            .get("sdk_versions")
            .and_then(Value::as_array)
            .is_some_and(|values| values.iter().any(|value| value.as_str() == Some(sdk)))
    {
        return false;
    }
    if let Some(simulator) = required.simulator.as_deref()
        && !capabilities
            .get("simulators")
            .and_then(Value::as_array)
            .is_some_and(|values| values.iter().any(|value| value.as_str() == Some(simulator)))
    {
        return false;
    }
    true
}

pub(super) fn version_less_than(actual: &str, minimum: &str) -> bool {
    fn components(value: &str) -> Vec<u64> {
        value
            .split('.')
            .map_while(|part| part.parse::<u64>().ok())
            .collect()
    }
    let actual = components(actual);
    let minimum = components(minimum);
    if actual.is_empty() || minimum.is_empty() {
        return true;
    }
    for index in 0..actual.len().max(minimum.len()) {
        match actual
            .get(index)
            .copied()
            .unwrap_or(0)
            .cmp(&minimum.get(index).copied().unwrap_or(0))
        {
            std::cmp::Ordering::Less => return true,
            std::cmp::Ordering::Greater => return false,
            std::cmp::Ordering::Equal => {}
        }
    }
    false
}

pub(super) fn parse_time(value: &str) -> Option<time::OffsetDateTime> {
    time::OffsetDateTime::parse(value, &Rfc3339).ok()
}

pub(super) fn validate_result_times(
    evidence: &crate::build_protocol::BuildResultEvidence,
    now: time::OffsetDateTime,
) -> Result<(), &'static str> {
    let started = parse_time(&evidence.started_at).ok_or("BUILD_RESULT_TIME_INVALID")?;
    let completed = parse_time(&evidence.completed_at).ok_or("BUILD_RESULT_TIME_INVALID")?;
    if started > completed || completed > now.saturating_add(time::Duration::minutes(5)) {
        return Err("BUILD_RESULT_TIME_INVALID");
    }
    Ok(())
}

pub(super) fn artifacts_match(
    uploaded: &[store::BuildArtifactRow],
    evidence: &[BuildArtifactEvidence],
) -> bool {
    if uploaded.len() != evidence.len() {
        return false;
    }
    let mut unmatched = uploaded.iter().collect::<Vec<_>>();
    evidence.iter().all(|item| {
        unmatched
            .iter()
            .position(|stored| {
                stored.id == item.artifact_id
                    && stored.kind == item.kind
                    && stored.relative_path == item.relative_path
                    && stored.sha256 == item.sha256
                    && stored.size_bytes == item.size_bytes
            })
            .map(|index| unmatched.swap_remove(index))
            .is_some()
    })
}

/// Length-checked, branch-free byte comparison for secret material.
pub(super) fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        difference |= a ^ b;
    }
    difference == 0
}

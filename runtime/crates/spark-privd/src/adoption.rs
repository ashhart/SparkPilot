//! Validate adopted vLLM containers inside the privileged helper and return only redacted evidence.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::backend::{INFERENCE_CONTAINER_PORT, INFERENCE_ISOLATED_NETWORK};

pub const MAX_INSPECT_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelAdoptionPolicy {
    pub workload_id: String,
    pub recipe_id: String,
    pub profile_id: String,
    pub image_digest: String,
    pub served_name: String,
    pub model_snapshot: String,
    pub gpu_memory_utilisation_milli: u16,
    pub max_model_length: u64,
    pub max_sequences: u32,
    pub max_batched_tokens: u64,
    pub allow_network_during_inference: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdoptionInspection {
    pub eligible: bool,
    pub evidence_digest: String,
    pub workload_id: String,
    pub host_port: Option<u16>,
    pub mismatch_codes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerContainer {
    id: String,
    config: DockerConfig,
    state: DockerState,
    host_config: DockerHostConfig,
    mounts: Vec<DockerMount>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerConfig {
    image: String,
    #[serde(default)]
    entrypoint: Vec<String>,
    #[serde(default)]
    cmd: Vec<String>,
    #[serde(default)]
    env: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerState {
    running: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerHostConfig {
    network_mode: String,
    readonly_rootfs: bool,
    privileged: bool,
    pid_mode: String,
    ipc_mode: String,
    #[serde(default)]
    cap_drop: Vec<String>,
    #[serde(default)]
    security_opt: Vec<String>,
    #[serde(default)]
    tmpfs: BTreeMap<String, String>,
    #[serde(default)]
    port_bindings: BTreeMap<String, Option<Vec<DockerPortBinding>>>,
    #[serde(default)]
    pids_limit: Option<i64>,
    #[serde(default)]
    ulimits: Vec<DockerUlimit>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerPortBinding {
    host_ip: String,
    host_port: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerUlimit {
    name: String,
    soft: i64,
    hard: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct DockerMount {
    r#type: String,
    source: String,
    destination: String,
    #[serde(rename = "RW")]
    rw: bool,
}

#[derive(Serialize)]
struct DigestEvidence<'a> {
    workload_id: &'a str,
    image_digest: &'a str,
    entrypoint: &'a [String],
    arguments: &'a [String],
    model_mount_source: Option<&'a str>,
    network_mode: &'a str,
    host_port: Option<u16>,
    environment_digest: String,
    running: bool,
}

pub fn inspect(
    container_json: &[u8],
    image_environment_json: &[u8],
    policy: &ModelAdoptionPolicy,
) -> Result<AdoptionInspection, String> {
    if container_json.len() > MAX_INSPECT_BYTES || image_environment_json.len() > MAX_INSPECT_BYTES
    {
        return Err("container inspection exceeded the fixed limit".into());
    }
    let container: DockerContainer = serde_json::from_slice(container_json)
        .map_err(|_| "container inspection had an unsupported shape")?;
    let image_environment: Vec<String> = serde_json::from_slice(image_environment_json)
        .map_err(|_| "image environment inspection had an unsupported shape")?;
    let mut mismatches = BTreeSet::new();

    if container.id != policy.workload_id {
        mismatches.insert("WORKLOAD_ID_MISMATCH");
    }
    if !container.state.running {
        mismatches.insert("WORKLOAD_NOT_RUNNING");
    }
    if container.config.image != policy.image_digest || !digest_pinned(&container.config.image) {
        mismatches.insert("IMAGE_DIGEST_MISMATCH");
    }
    if container.config.entrypoint != ["vllm"] {
        mismatches.insert("ENTRYPOINT_MISMATCH");
    }

    let (host_port, expected_arguments) = expected_arguments(policy, &container.host_config);
    if container.config.cmd != expected_arguments {
        mismatches.insert("ARGUMENTS_MISMATCH");
    }

    let model_mount = container
        .mounts
        .iter()
        .find(|mount| mount.destination == "/model");
    let exact_mount = model_mount.is_some_and(|mount| {
        mount.r#type == "bind"
            && mount.source == policy.model_snapshot
            && !mount.rw
            && container.mounts.len() == 1
    });
    if !exact_mount {
        mismatches.insert("MOUNTS_MISMATCH");
    }
    if container.host_config.tmpfs.len() != 1
        || container.host_config.tmpfs.get("/tmp").map(String::as_str)
            != Some("rw,nosuid,nodev,noexec,size=4g")
    {
        mismatches.insert("MOUNTS_MISMATCH");
    }

    if !network_matches(&container.host_config, policy, host_port) {
        mismatches.insert("NETWORK_POLICY_MISMATCH");
    }
    if !security_matches(&container.host_config) {
        mismatches.insert("CONTAINER_SECURITY_MISMATCH");
    }

    // Exact image-default environment matching rejects hidden credentials or overrides without disclosing their values.
    if canonical_environment(&container.config.env) != canonical_environment(&image_environment) {
        mismatches.insert("CONFIGURATION_MISMATCH");
    }

    let environment_digest = digest_json(&canonical_environment(&container.config.env))?;
    let evidence = DigestEvidence {
        workload_id: &container.id,
        image_digest: &container.config.image,
        entrypoint: &container.config.entrypoint,
        arguments: &container.config.cmd,
        model_mount_source: model_mount.map(|mount| mount.source.as_str()),
        network_mode: &container.host_config.network_mode,
        host_port,
        environment_digest,
        running: container.state.running,
    };
    Ok(AdoptionInspection {
        eligible: mismatches.is_empty(),
        evidence_digest: digest_json(&evidence)?,
        workload_id: container.id,
        host_port,
        mismatch_codes: mismatches.into_iter().map(str::to_owned).collect(),
    })
}

fn expected_arguments(
    policy: &ModelAdoptionPolicy,
    host: &DockerHostConfig,
) -> (Option<u16>, Vec<String>) {
    let host_port = if policy.allow_network_during_inference {
        None
    } else {
        host.port_bindings
            .get(&format!("{INFERENCE_CONTAINER_PORT}/tcp"))
            .and_then(Option::as_ref)
            .and_then(|bindings| (bindings.len() == 1).then_some(&bindings[0]))
            .and_then(|binding| binding.host_port.parse().ok())
    };
    let port = INFERENCE_CONTAINER_PORT;
    let host_value = "0.0.0.0";
    (
        host_port,
        vec![
            "serve".into(),
            "/model".into(),
            "--served-model-name".into(),
            policy.served_name.clone(),
            "--host".into(),
            host_value.into(),
            "--port".into(),
            port.to_string(),
            "--gpu-memory-utilization".into(),
            format!(
                "{:.3}",
                f64::from(policy.gpu_memory_utilisation_milli) / 1000.0
            ),
            "--max-model-len".into(),
            policy.max_model_length.to_string(),
            "--max-num-seqs".into(),
            policy.max_sequences.to_string(),
            "--max-num-batched-tokens".into(),
            policy.max_batched_tokens.to_string(),
            "--enable-prefix-caching".into(),
        ],
    )
}

fn network_matches(
    host: &DockerHostConfig,
    policy: &ModelAdoptionPolicy,
    host_port: Option<u16>,
) -> bool {
    if policy.allow_network_during_inference {
        return host.network_mode == "host" && host.port_bindings.is_empty();
    }
    let Some(port) = host_port else { return false };
    let bindings = host
        .port_bindings
        .get(&format!("{INFERENCE_CONTAINER_PORT}/tcp"))
        .and_then(Option::as_ref);
    host.network_mode == INFERENCE_ISOLATED_NETWORK
        && host.port_bindings.len() == 1
        && bindings.is_some_and(|bindings| {
            bindings.len() == 1
                && bindings[0].host_ip == "127.0.0.1"
                && bindings[0].host_port == port.to_string()
        })
}

fn security_matches(host: &DockerHostConfig) -> bool {
    let cap_drop = host
        .cap_drop
        .iter()
        .map(|value| value.to_ascii_uppercase())
        .collect::<BTreeSet<_>>();
    let security = host
        .security_opt
        .iter()
        .map(|value| value.to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    let ulimits = host
        .ulimits
        .iter()
        .map(|limit| (limit.name.as_str(), limit.soft, limit.hard))
        .collect::<BTreeSet<_>>();
    host.readonly_rootfs
        && !host.privileged
        && host.pid_mode.is_empty()
        && host.ipc_mode == "host"
        && cap_drop == BTreeSet::from(["ALL".to_owned()])
        && security.contains("no-new-privileges:true")
        && host.pids_limit == Some(2048)
        && ulimits == BTreeSet::from([("memlock", -1, -1), ("stack", 67_108_864, 67_108_864)])
}

fn canonical_environment(values: &[String]) -> Vec<String> {
    let mut values = values.to_vec();
    values.sort();
    values
}

pub fn valid_workload_id(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn digest_pinned(value: &str) -> bool {
    let Some((repository, digest)) = value.rsplit_once('@') else {
        return false;
    };
    let hex = digest.strip_prefix("sha256:").unwrap_or_default();
    !repository.is_empty() && hex.len() == 64 && hex.chars().all(|value| value.is_ascii_hexdigit())
}

fn digest_json(value: &impl Serialize) -> Result<String, String> {
    let bytes = serde_json::to_vec(value).map_err(|_| "adoption evidence could not be encoded")?;
    Ok(hex::encode(Sha256::digest(bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    type FixtureMutation = (&'static str, Box<dyn Fn(&mut Value)>);

    fn policy() -> ModelAdoptionPolicy {
        ModelAdoptionPolicy {
            workload_id: "a".repeat(64),
            recipe_id: "example/model".into(),
            profile_id: "balanced".into(),
            image_digest: format!("nvcr.io/nvidia/vllm@sha256:{}", "b".repeat(64)),
            served_name: "example-model".into(),
            model_snapshot:
                "/var/lib/spark-runtime/models/snapshots/example/model/0123456789abcdef0123456789abcdef01234567"
                    .into(),
            gpu_memory_utilisation_milli: 720,
            max_model_length: 16_384,
            max_sequences: 4,
            max_batched_tokens: 8_192,
            allow_network_during_inference: false,
        }
    }

    fn fixture() -> Value {
        let policy = policy();
        json!({
            "Id": policy.workload_id,
            "Config": {
                "Image": policy.image_digest,
                "Entrypoint": ["vllm"],
                "Cmd": [
                    "serve", "/model", "--served-model-name", "example-model",
                    "--host", "0.0.0.0", "--port", "8000",
                    "--gpu-memory-utilization", "0.720", "--max-model-len", "16384",
                    "--max-num-seqs", "4", "--max-num-batched-tokens", "8192",
                    "--enable-prefix-caching"
                ],
                "Env": ["PATH=/usr/local/bin"]
            },
            "State": { "Running": true },
            "HostConfig": {
                "NetworkMode": "spark-inference-isolated",
                "ReadonlyRootfs": true,
                "Privileged": false,
                "PidMode": "",
                "IpcMode": "host",
                "CapDrop": ["ALL"],
                "SecurityOpt": ["no-new-privileges:true"],
                "Tmpfs": { "/tmp": "rw,nosuid,nodev,noexec,size=4g" },
                "PortBindings": {
                    "8000/tcp": [{ "HostIp": "127.0.0.1", "HostPort": "18123" }]
                },
                "PidsLimit": 2048,
                "Ulimits": [
                    { "Name": "memlock", "Soft": -1, "Hard": -1 },
                    { "Name": "stack", "Soft": 67108864, "Hard": 67108864 }
                ]
            },
            "Mounts": [{
                "Type": "bind",
                "Source": policy.model_snapshot,
                "Destination": "/model",
                "RW": false
            }]
        })
    }

    fn run(value: &Value) -> AdoptionInspection {
        inspect(
            &serde_json::to_vec(value).unwrap(),
            br#"["PATH=/usr/local/bin"]"#,
            &policy(),
        )
        .unwrap()
    }

    #[test]
    fn exact_digest_recipe_model_arguments_mount_network_ports_and_health_shape_match() {
        let inspection = run(&fixture());
        assert!(inspection.eligible, "{:?}", inspection.mismatch_codes);
        assert_eq!(inspection.host_port, Some(18123));
        assert_eq!(inspection.evidence_digest.len(), 64);
    }

    #[test]
    fn mutable_tag_and_every_consequential_mismatch_fail_closed() {
        let mutations: [FixtureMutation; 7] = [
            (
                "IMAGE_DIGEST_MISMATCH",
                Box::new(|v| v["Config"]["Image"] = json!("vllm:latest")),
            ),
            (
                "ARGUMENTS_MISMATCH",
                Box::new(|v| v["Config"]["Cmd"][3] = json!("wrong-model")),
            ),
            (
                "ARGUMENTS_MISMATCH",
                Box::new(|v| {
                    v["Config"]["Cmd"]
                        .as_array_mut()
                        .unwrap()
                        .push(json!("--trust-remote-code"))
                }),
            ),
            (
                "MOUNTS_MISMATCH",
                Box::new(|v| v["Mounts"][0]["Source"] = json!("/tmp/model")),
            ),
            (
                "NETWORK_POLICY_MISMATCH",
                Box::new(|v| v["HostConfig"]["NetworkMode"] = json!("host")),
            ),
            (
                "NETWORK_POLICY_MISMATCH",
                Box::new(|v| {
                    v["HostConfig"]["PortBindings"]["8000/tcp"][0]["HostIp"] = json!("0.0.0.0")
                }),
            ),
            (
                "CONTAINER_SECURITY_MISMATCH",
                Box::new(|v| v["HostConfig"]["Privileged"] = json!(true)),
            ),
        ];
        for (expected, mutate) in mutations {
            let mut value = fixture();
            mutate(&mut value);
            let result = run(&value);
            assert!(!result.eligible);
            assert!(result.mismatch_codes.iter().any(|code| code == expected));
        }
    }

    #[test]
    fn environment_override_is_rejected_without_returning_its_secret() {
        let mut value = fixture();
        value["Config"]["Env"] = json!([
            "PATH=/usr/local/bin",
            "VLLM_API_KEY=never-return-this-secret"
        ]);
        let encoded = serde_json::to_string(&run(&value)).unwrap();
        assert!(encoded.contains("CONFIGURATION_MISMATCH"));
        assert!(!encoded.contains("never-return-this-secret"));
    }

    #[test]
    fn a_spoofed_container_name_cannot_influence_exact_matching() {
        let mut value = fixture();
        value["Name"] = json!("/spark-model-example-model");
        let first = run(&value);
        value["Name"] = json!("/pretend-this-is-managed");
        let second = run(&value);

        assert!(first.eligible);
        assert_eq!(first, second);
    }

    #[test]
    fn only_a_full_docker_container_id_is_accepted() {
        assert!(valid_workload_id(&"a".repeat(64)));
        assert!(!valid_workload_id(&"a".repeat(12)));
        assert!(!valid_workload_id(&format!("{}g", "a".repeat(63))));
    }
}

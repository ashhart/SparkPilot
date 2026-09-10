use super::*;
use crate::protocol::SecretString;
use crate::update::CommandOutput;
use std::sync::{Arc, Mutex, MutexGuard};

static CASE: Mutex<()> = Mutex::new(());
#[derive(Default)]
struct DockerState {
    containers: HashMap<String, Value>,
    volumes: HashMap<String, Value>,
    calls: Vec<Vec<String>>,
    next: u64,
    lose_create_receipt: bool,
    replace_during_pull: bool,
}
struct Docker {
    state: Mutex<DockerState>,
    data: PathBuf,
    journal: PathBuf,
}
impl Docker {
    fn success(stdout: Vec<u8>) -> Result<CommandOutput, String> {
        Ok(CommandOutput {
            status: Some(0),
            stdout,
            stderr: Vec::new(),
        })
    }
    fn missing(kind: &str) -> Result<CommandOutput, String> {
        Ok(CommandOutput {
            status: Some(1),
            stdout: Vec::new(),
            stderr: format!("No such {kind}").into_bytes(),
        })
    }
    fn current_id(&self) -> String {
        self.state
            .lock()
            .unwrap()
            .containers
            .values()
            .find(|value| value["Name"] == OPEN_WEBUI_CONTAINER)
            .unwrap()["Id"]
            .as_str()
            .unwrap()
            .into()
    }
}
impl CommandRunner for Docker {
    fn run(&self, _program: &str, args: &[String]) -> Result<CommandOutput, String> {
        let mut state = self.state.lock().unwrap();
        state.calls.push(args.to_vec());
        match args[0].as_str() {
            "ps" => Self::success(
                state
                    .containers
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("\n")
                    .into_bytes(),
            ),
            "container" if args[1] == "inspect" => {
                let value = state.containers.get(&args[2]).or_else(|| {
                    state
                        .containers
                        .values()
                        .find(|value| value["Name"] == args[2])
                });
                match value {
                    Some(value) => Self::success(serde_json::to_vec(&json!([value])).unwrap()),
                    None => Self::missing("container"),
                }
            }
            "volume" if args[1] == "inspect" => match state.volumes.get(&args[2]) {
                Some(value) => Self::success(serde_json::to_vec(&json!([value])).unwrap()),
                None => Self::missing("volume"),
            },
            "volume" if args[1] == "create" => {
                let name = args.last().unwrap();
                let mountpoint = self.data.join(name);
                fs::create_dir(&mountpoint).unwrap();
                let label = args[4].strip_prefix("spark.ownership=").unwrap();
                state.volumes.insert(name.clone(), json!({"Name":name,"Driver":"local","Options":{},"Labels":{"spark.ownership":label},"Mountpoint":mountpoint,"CreatedAt":"2026-09-04T15:00:00Z"}));
                Self::success(name.as_bytes().to_vec())
            }
            "volume" if args[1] == "rm" => {
                state.volumes.remove(&args[2]);
                Self::success(Vec::new())
            }
            "pull" => {
                if state.replace_during_pull {
                    state.replace_during_pull = false;
                    let id = state
                        .containers
                        .values()
                        .find(|v| v["Name"] == OPEN_WEBUI_CONTAINER)
                        .unwrap()["Id"]
                        .as_str()
                        .unwrap()
                        .to_owned();
                    let mut replacement = state.containers.remove(&id).unwrap();
                    let other = "e".repeat(64);
                    replacement["Id"] = json!(other);
                    state.containers.insert(other, replacement);
                }
                Self::success(Vec::new())
            }
            "create" => {
                let option = |prefix: &str| {
                    args.iter()
                        .find_map(|arg| arg.strip_prefix(prefix))
                        .unwrap()
                };
                let name = option("--name=");
                if state.containers.values().any(|value| value["Name"] == name) {
                    return Err("name collision".into());
                }
                let volume = option("--volume=").split(':').next().unwrap();
                let env_file = option("--env-file=");
                let mut env: Vec<String> = fs::read_to_string(env_file)
                    .unwrap()
                    .lines()
                    .map(str::to_owned)
                    .collect();
                env.extend(
                    args.iter()
                        .filter_map(|arg| arg.strip_prefix("--env=").map(str::to_owned)),
                );
                state.next += 1;
                let id = format!("{:064x}", state.next);
                let image = args.last().unwrap();
                let value = json!({"Id":id,"Name":name,"Image":format!("sha256:{}","b".repeat(64)),
                    "Config":{"Image":image,"Env":env,"Labels":{"spark.ownership":option("--label=spark.ownership="),"spark.service":"open-webui"}},
                    "HostConfig":{"NetworkMode":"host","ReadonlyRootfs":true,"Privileged":false,"RestartPolicy":{"Name":option("--restart=")},"CapDrop":["ALL"],"SecurityOpt":["no-new-privileges:true"]},
                    "Mounts":[{"Type":"volume","Name":volume,"Destination":"/app/backend/data"}],"State":{"Running":false}});
                state.containers.insert(id.clone(), value);
                if state.lose_create_receipt {
                    state.lose_create_receipt = false;
                    return Err("interrupted create receipt".into());
                }
                Self::success(id.into_bytes())
            }
            "start" | "restart" | "stop" | "rm" | "rename" => {
                let id = if args[0] == "rename" {
                    &args[1]
                } else {
                    args.last().unwrap()
                };
                assert!(
                    valid_id(id),
                    "every container mutation must use an immutable ID"
                );
                let recorded: Journal =
                    serde_json::from_slice(&fs::read(&self.journal).unwrap()).unwrap();
                assert!(
                    recorded
                        .current
                        .iter()
                        .chain(recorded.previous.iter())
                        .any(|container| &container.id == id),
                    "receipt precedes mutation"
                );
                if args[0] == "rm" {
                    state.containers.remove(id);
                } else {
                    let value = state.containers.get_mut(id).ok_or("missing ID")?;
                    if args[0] == "rename" {
                        value["Name"] = json!(args[2]);
                    } else {
                        value["State"]["Running"] = json!(args[0] != "stop");
                    }
                }
                Self::success(Vec::new())
            }
            _ => Err(format!("unexpected Docker command: {}", args[0])),
        }
    }
    fn run_with_secret_input(
        &self,
        _: &str,
        _: &[String],
        _: &str,
    ) -> Result<CommandOutput, String> {
        panic!("no stdin command")
    }
}
struct Fixture {
    _serial: MutexGuard<'static, ()>,
    _directory: tempfile::TempDir,
    backend: DockerBackend,
    docker: Arc<Docker>,
    health: Arc<Mutex<std::collections::VecDeque<bool>>>,
}
impl Fixture {
    fn new() -> Self {
        let serial = CASE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let directory = tempfile::tempdir().unwrap();
        let runtime = directory.path().join("run");
        fs::create_dir(&runtime).unwrap();
        let data = directory.path().join("volumes");
        fs::create_dir(&data).unwrap();
        let health = Arc::new(Mutex::new(std::collections::VecDeque::new()));
        let probe = health.clone();
        let docker = Arc::new(Docker {
            state: Mutex::new(DockerState::default()),
            data,
            journal: runtime.join("open-webui-owned/ownership.json"),
        });
        let mut backend = DockerBackend::new("fake-docker", false)
            .with_paths(directory.path().join("models"), runtime);
        backend.appliance_command_runner = docker.clone();
        backend.open_webui_probe = Some(Arc::new(move || {
            probe.lock().unwrap().pop_front().unwrap_or(true)
        }));
        Self {
            _serial: serial,
            _directory: directory,
            backend,
            docker,
            health,
        }
    }
    fn install(&self) {
        assert!(
            self.backend
                .execute(&PrivilegedOperation::InstallOpenWebUi {
                    request_id: uuid::Uuid::new_v4(),
                    image_digest: image('a'),
                    admin_email: "owner@example.test".into(),
                    admin_name: "Owner".into(),
                    admin_password: SecretString::new("a-test-owner-password-42"),
                    gateway_api_key: SecretString::new("g".repeat(48)),
                    port: 18080,
                    adopt_existing: false
                })
                .unwrap()
                .accepted
        );
    }
    fn repair(&self) -> PrivilegedResponse {
        self.backend
            .execute(&PrivilegedOperation::RepairOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
            })
            .unwrap()
    }
    fn remove(&self, erase_data: bool) -> PrivilegedResponse {
        self.backend
            .execute(&PrivilegedOperation::RemoveOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
                erase_data,
            })
            .unwrap()
    }
    fn update(&self) -> PrivilegedResponse {
        self.backend
            .execute(&PrivilegedOperation::UpdateOpenWebUi {
                request_id: uuid::Uuid::new_v4(),
                image_digest: image('c'),
            })
            .unwrap()
    }
}
fn image(digit: char) -> String {
    format!(
        "ghcr.io/open-webui/open-webui@sha256:{}",
        digit.to_string().repeat(64)
    )
}

include!(
    "tests/scenarios/bootstrap_records_before_start_scrubs_credentials_and_removes_exact_ids.rs"
);
include!("tests/scenarios/identical_image_and_copied_labels_do_not_adopt_a_replacement_id.rs");
include!("tests/scenarios/missing_receipt_and_changed_privilege_fail_before_any_mutation.rs");
include!("tests/scenarios/recreated_same_name_volume_is_never_erased_or_reused.rs");
include!("tests/scenarios/failed_update_restores_exact_previous_container_and_owned_data.rs");
include!("tests/scenarios/successful_update_removes_only_old_id_and_keeps_data_for_reinstall.rs");
include!("tests/scenarios/repair_refuses_stops_restarts_once_and_persists_cooldown.rs");
include!("tests/scenarios/interrupted_update_rolls_back_from_durable_ids_after_helper_restart.rs");
include!(
    "tests/scenarios/interrupted_create_without_receipt_preserves_objects_and_refuses_adoption.rs"
);
include!(
    "tests/scenarios/interrupted_data_removal_finishes_without_recreating_or_adopting_storage.rs"
);
include!("tests/scenarios/tampered_or_symlinked_root_receipt_is_not_trusted.rs");
include!(
    "tests/scenarios/ownership_is_rechecked_after_slow_image_pull_before_stopping_anything.rs"
);

include!("tests/scenarios/interrupted_scrubbed_install_can_complete_without_another_bootstrap.rs");
include!("tests/scenarios/interrupted_promotion_finishes_after_previous_container_was_removed.rs");

include!("tests/scenarios/adoption_preserves_external_container_and_custom_port.rs");

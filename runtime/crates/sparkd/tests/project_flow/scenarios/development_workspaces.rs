#[tokio::test]
async fn development_checkout_survives_manager_restart_and_keeps_the_same_files() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "durable", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let first = h.projects.ensure_development_workspace(&project).unwrap();
    let workspace = h.projects.development_workspace(&project).unwrap();
    assert_ne!(workspace.root_path, project.root_path);
    h.projects.file_save(&workspace, "notes.txt", b"still here", REVISION_EMPTY).unwrap();
    let reopened = ProjectManager::new(Arc::new(CommandGit::new("git")), h.containers.clone(), h.pty.clone(),
        h.state.database.as_ref().unwrap().clone(), sparkd::jobs::JobService::new(), sparkd::events::EventBus::new(),
        SIGNING_NODE_ID.to_string(), h._dir.path().join("projects"), h._dir.path().join("worktrees"));
    let second = reopened.ensure_development_workspace(&project).unwrap();
    assert_eq!(first.worktree_path, second.worktree_path);
    assert_eq!(reopened.file_read(&reopened.development_workspace(&project).unwrap(), "notes.txt").unwrap(), b"still here");
    assert!(reopened.file_read(&project, "notes.txt").is_err());
}

#[tokio::test]
async fn development_files_are_project_scoped_and_internal_harness_state_is_hidden() {
    let (h, addr, key, owner) = harness().await;
    for name in ["one", "two"] {
        h.projects.create_project(uuid::Uuid::new_v4(), name, None, None, &owner).unwrap();
    }
    let projects = h.projects.list().unwrap();
    let one = &projects[0]; let two = &projects[1];
    h.projects.ensure_development_workspace(one).unwrap();
    h.projects.ensure_development_workspace(two).unwrap();
    let workspace = h.projects.development_workspace(one).unwrap();
    h.projects.file_save(&workspace, "hello.txt", b"first workspace", REVISION_EMPTY).unwrap();
    assert!(h.projects.file_save(&workspace, ".spark-home/auth.json", b"secret", REVISION_EMPTY).is_err());
    assert_ne!(workspace.root_path, h.projects.development_workspace(two).unwrap().root_path);
    let client = reqwest::Client::new();
    let (status, body) = signed_json(&client, addr, &key, &owner, "GET",
        &format!("/api/v1/projects/{}/files/hello.txt?workspace=development", one.id), None).await;
    assert_eq!(status, reqwest::StatusCode::OK, "{body}");
    assert_eq!(body["content"], "first workspace");
    let (status, _) = signed_json(&client, addr, &key, &owner, "GET",
        &format!("/api/v1/projects/{}/files/hello.txt?workspace=development", two.id), None).await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND);
}

async fn development_test_socket(addr: SocketAddr, key: &p256::ecdsa::SigningKey, owner: &uuid::Uuid, project: &str, terminal: &str)
    -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::{HeaderName, HeaderValue}};
    let mut request = format!("ws://{addr}/api/v1/projects/{project}/terminals/{terminal}/ws").into_client_request().unwrap();
    let (headers, _) = signed_parts(key, owner, "GET", &ws_url_http(&addr, project, terminal), &[]);
    for (name, value) in headers { request.headers_mut().insert(HeaderName::from_bytes(name.as_bytes()).unwrap(), HeaderValue::from_str(&value).unwrap()); }
    tokio_tungstenite::connect_async(request).await.unwrap().0
}

async fn development_test_read_until<S>(socket: &mut S, expected: &str) -> String
where S: futures::Stream<Item = Result<tokio_tungstenite::tungstenite::Message, tokio_tungstenite::tungstenite::Error>> + Unpin {
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut transcript = String::new();
        while let Some(Ok(message)) = socket.next().await {
            if let tokio_tungstenite::tungstenite::Message::Text(text) = message {
                let value: Value = serde_json::from_str(&text).unwrap();
                if let Some(data) = value.get("data").and_then(Value::as_str) { transcript.push_str(data); }
                if transcript.contains(expected) { return transcript; }
            }
        }
        panic!("socket closed before {expected}: {transcript}")
    }).await.expect("terminal output deadline")
}

#[tokio::test]
async fn two_windows_receive_the_same_output_and_detached_sessions_replay_without_duplicate_processes() {
    let (h, addr, key, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "two windows", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    write_devcontainer(&project.root_path);
    let id = uuid::Uuid::new_v4();
    h.projects.terminal_create(id, &project, owner, spark_project_runner::TerminalShell::Login, 100, 35).unwrap();
    let project_id = project.id.to_string(); let terminal = id.to_string();
    let mut first = development_test_socket(addr, &key, &owner, &project_id, &terminal).await;
    let mut second = development_test_socket(addr, &key, &owner, &project_id, &terminal).await;
    h.projects.terminal(&project.id, &id).unwrap().session.lock().write("shared λ 東京\r\n".as_bytes()).unwrap();
    assert!(development_test_read_until(&mut first, "shared λ 東京").await.contains("shared"));
    assert!(development_test_read_until(&mut second, "shared λ 東京").await.contains("shared"));
    first.close(None).await.unwrap(); second.close(None).await.unwrap();
    h.projects.terminal(&project.id, &id).unwrap().session.lock().write(b"completed while away\r\n").unwrap();
    let mut reopened = development_test_socket(addr, &key, &owner, &project_id, &terminal).await;
    let replay = development_test_read_until(&mut reopened, "completed while away").await;
    assert!(replay.contains("shared λ 東京"));
    assert_eq!(h.pty.requests().len(), 1);
    assert_eq!(h.projects.terminals_for_project(&project.id), vec![id]);
    h.projects.terminal_close(&project.id, &id).unwrap();
}

#[tokio::test]
async fn session_state_distinguishes_preparation_and_confirmed_loss_without_leaking_other_projects() {
    let (h, addr, key, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "pending", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let terminal = uuid::Uuid::new_v4();
    let reservation = h.projects.reserve_terminal(project.id, terminal).unwrap();
    let path = format!("/api/v1/projects/{}/terminals/{terminal}", project.id);
    let client = reqwest::Client::new();
    let (status, body) = signed_json(&client, addr, &key, &owner, "GET", &path, None).await;
    assert_eq!(status, reqwest::StatusCode::OK); assert_eq!(body["state"], "starting");
    assert_eq!(h.projects.terminal_state(&uuid::Uuid::new_v4(), &terminal), None);
    drop(reservation);
    let (status, body) = signed_json(&client, addr, &key, &owner, "GET", &path, None).await;
    assert_eq!(status, reqwest::StatusCode::NOT_FOUND); assert_eq!(body["error"]["code"], "TERMINAL_NOT_FOUND");
}

#[tokio::test]
async fn development_git_exclusions_cover_credentials_and_refuse_symlinked_metadata() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "exclusions", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    h.projects.ensure_development_workspace(&project).unwrap();
    let workspace = h.projects.development_workspace(&project).unwrap();
    // A clone made with an empty Git template need not have this file.
    std::fs::remove_file(workspace.root_path.join(".git/info/exclude")).unwrap();
    h.projects.ensure_development_workspace(&project).unwrap();
    for file in [".spark-home/auth.json", ".spark-session-example.json", ".g-example"] {
        let status = std::process::Command::new("git").arg("-C").arg(&workspace.root_path)
            .args(["check-ignore", "-q", file]).status().unwrap();
        assert!(status.success(), "{file} must not become Git content");
    }
    let exclude = workspace.root_path.join(".git/info/exclude");
    std::fs::remove_file(&exclude).unwrap();
    let outside = h._dir.path().join("outside-exclude");
    std::fs::write(&outside, "untouched").unwrap();
    std::os::unix::fs::symlink(&outside, &exclude).unwrap();
    assert!(h.projects.ensure_development_workspace(&project).is_err());
    assert_eq!(std::fs::read_to_string(outside).unwrap(), "untouched");
}

#[tokio::test]
async fn ending_a_session_during_preparation_prevents_a_late_agent_spawn() {
    let (h, addr, key, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "cancel launch", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let terminal = uuid::Uuid::new_v4();
    let _reservation = h.projects.reserve_terminal(project.id, terminal).unwrap();
    let path = format!("/api/v1/projects/{}/terminals/{terminal}", project.id);
    let (status, _) = signed_json(&reqwest::Client::new(), addr, &key, &owner, "DELETE", &path, None).await;
    assert_eq!(status, reqwest::StatusCode::OK);
    assert_eq!(h.projects.terminal_state(&project.id, &terminal), Some("stopped"));
    let container = h.projects.ensure_development_workspace(&project).unwrap();
    let result = h.projects.development_terminal_create(terminal, project.id, owner, 100, 30, container);
    assert!(matches!(result, Err(error) if error == "TERMINAL_LAUNCH_CANCELLED"));
    assert!(h.pty.requests().is_empty());
}

#[tokio::test]
async fn claude_requires_a_local_model_instead_of_falling_back_to_an_external_account() {
    let (h, addr, key, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "external harness", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    let path = format!("/api/v1/projects/{}/terminals", project.id);
    let body = json!({"shell":"development", "development":{
        "harness":"claude_code", "model_id":"anthropic-account", "workspace_session_id":uuid::Uuid::new_v4()
    }});
    let (status, response) = signed_json(&reqwest::Client::new(), addr, &key, &owner, "POST", &path, Some(body)).await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{response}");
    let terminal: uuid::Uuid = response["terminal_id"].as_str().unwrap().parse().unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while h.projects.terminal_state(&project.id, &terminal) == Some("starting") {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }).await.unwrap();
    assert_eq!(h.projects.terminal_state(&project.id, &terminal), Some("failed"));
    assert!(h.projects.terminal_failure(&project.id, &terminal).is_some());
    assert!(h.pty.requests().is_empty(), "no cloud-backed harness may start without a local engine");
    assert!(h.projects.development_workspace(&project).is_err(), "validation must precede workspace creation");
}

#[tokio::test]
async fn failed_privileged_close_keeps_the_session_available_for_retry() {
    let (h, _, _, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "close retry", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    write_devcontainer(&project.root_path);
    let terminal = h.projects.terminal_create(uuid::Uuid::new_v4(), &project, owner, spark_project_runner::TerminalShell::Login, 80, 24).unwrap();
    h.pty.set_close_failure(true);
    assert!(h.projects.terminal_close(&project.id, &terminal.terminal_id).is_err());
    assert!(h.projects.terminal(&project.id, &terminal.terminal_id).is_ok());
    h.pty.set_close_failure(false);
    h.projects.terminal_close(&project.id, &terminal.terminal_id).unwrap();
    assert!(h.projects.terminal(&project.id, &terminal.terminal_id).is_err());
}

#[tokio::test]
async fn an_existing_omp_install_reports_the_available_pinned_update() {
    let (h, addr, key, owner) = harness().await;
    h.projects.create_project(uuid::Uuid::new_v4(), "updates", None, None, &owner).unwrap();
    let project = h.projects.list().unwrap().remove(0);
    h.projects.ensure_development_workspace(&project).unwrap();
    let workspace = h.projects.development_workspace(&project).unwrap();
    let tools = workspace.root_path.join(".spark-home/tools");
    std::fs::create_dir_all(&tools).unwrap();
    std::fs::write(tools.join("omp-18.1.11"), b"old prepared binary").unwrap();
    let client = reqwest::Client::new();
    let path = format!("/api/v1/projects/{}", project.id);
    let (status, body) = signed_json(&client, addr, &key, &owner, "GET", &path, None).await;
    assert_eq!(status, reqwest::StatusCode::OK);
    assert_eq!(body["harness_updates"][0]["harness"], "oh_my_pi");
    assert_eq!(body["harness_updates"][0]["available_version"], "18.1.12");
    std::fs::write(tools.join("omp-18.1.12"), b"current prepared binary").unwrap();
    let (_, body) = signed_json(&client, addr, &key, &owner, "GET", &path, None).await;
    assert_eq!(body["harness_updates"], json!([]), "a prepared update does not keep nagging");
}

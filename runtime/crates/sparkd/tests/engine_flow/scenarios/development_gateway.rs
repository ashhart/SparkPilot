#[tokio::test]
async fn development_gateway_uses_the_selected_engine_and_revokes_with_project_access() {
    exercise_development_gateway("oh_my_pi").await;
    exercise_development_gateway("claude_code").await;
}

async fn exercise_development_gateway(harness_name: &str) {
    let (h, addr, key, owner) = harness(240 << 30).await;
    let client = reqwest::Client::new();
    let operation: uuid::Uuid = load_model(&client, addr, &key, &owner, None).await["id"]
        .as_str().unwrap().parse().unwrap();
    assert_eq!(wait_terminal(&h.state, operation, Duration::from_secs(10)).await["state"], "succeeded");
    let (_, active) = status_and_active_inference(&client, addr, &key, &owner).await;
    let model = active["model_id"].as_str().unwrap();
    // Keep the Unix-domain path below Darwin's sun_path limit, independent of the test runner's temp root.
    let directory = tempfile::Builder::new().prefix("sd-").tempdir_in("/tmp").unwrap();
    let projects = Arc::new(sparkd::project::ProjectManager::new(
        Arc::new(spark_project_runner::CommandGit::new("git")),
        Arc::new(spark_project_runner::FakeContainerBoundary::default()),
        Arc::new(spark_project_runner::ScriptedPtyRunner::default()),
        h.state.database.as_ref().unwrap().clone(), sparkd::jobs::JobService::new(), h.state.events.clone(),
        SIGNING_NODE_ID.to_string(), directory.path().join("p"), directory.path().join("w"),
    ));
    projects.create_project(uuid::Uuid::new_v4(), "gateway", None, None, &owner).unwrap();
    let project = projects.list().unwrap().remove(0);
    let state = h.state.clone().with_projects(projects.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, router(state)).await.unwrap(); });
    let (status, created) = signed_json(&client, address, &key, &owner, "POST",
        &format!("/api/v1/projects/{}/terminals", project.id), Some(json!({
            "shell": "development", "development": {"harness":harness_name, "model_id":model,
                "workspace_session_id":uuid::Uuid::new_v4()}
        }))).await;
    assert_eq!(status, reqwest::StatusCode::ACCEPTED, "{created}");
    let terminal: uuid::Uuid = created["terminal_id"].as_str().unwrap().parse().unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while projects.terminal_state(&project.id, &terminal) == Some("starting") {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }).await.unwrap();
    assert_eq!(projects.terminal_state(&project.id, &terminal), Some("running"), "{:?}", projects.terminal_failure(&project.id, &terminal));
    let root = projects.development_workspace(&project).unwrap().root_path;
    let config: Value = serde_json::from_slice(&std::fs::read(root.join(format!(".spark-session-{terminal}.json"))).unwrap()).unwrap();
    let socket = root.join(config["socket"].as_str().unwrap());
    let gateway = reqwest::Client::builder().unix_socket(socket.clone()).build().unwrap();
    let tools = gateway.post("http://workspace/spark/codex/prepare").send().await.unwrap();
    assert_eq!(tools.status(), reqwest::StatusCode::FORBIDDEN, "only Codex sessions can prepare Codex");
    let endpoint = if harness_name == "claude_code" { "messages" } else { "chat/completions" };
    let endpoint = format!("http://workspace/v1/{endpoint}");
    let body = json!({"model":model,"messages":[{"role":"user","content":"gateway test"}],"stream":false,"max_tokens":32});
    let response = gateway.post(&endpoint).json(&body).send().await.unwrap();
    let status = response.status(); let result = response.text().await.unwrap();
    assert_eq!(status, reqwest::StatusCode::OK, "{result}");
    assert!(result.contains(if harness_name == "claude_code" { "content" } else { "choices" }), "{result}");
    if harness_name == "claude_code" {
        let count = gateway.post("http://workspace/v1/messages/count_tokens")
            .json(&body).send().await.unwrap();
        assert_eq!(count.status(), reqwest::StatusCode::OK);
        assert_eq!(count.json::<Value>().await.unwrap()["input_tokens"], 12);
        let mut streaming = body.clone(); streaming["stream"] = true.into();
        let response = gateway.post(&endpoint).json(&streaming).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        let text = response.text().await.unwrap();
        assert!(text.contains("message_start") && text.contains("message_stop"), "{text}");
        assert!(!text.contains("[DONE]"), "native Messages protocol must be preserved");
        let refused_count = gateway.post("http://workspace/v1/messages/count_tokens")
            .json(&json!({"model":"wrong", "messages":[]})).send().await.unwrap();
        assert_eq!(refused_count.status(), reqwest::StatusCode::FORBIDDEN);
    }
    let refused = gateway.post(&endpoint)
        .json(&json!({"model":"a-different-model","messages":[]})).send().await.unwrap();
    assert_eq!(refused.status(), reqwest::StatusCode::FORBIDDEN);
    let unknown = gateway.post("http://workspace/v1/admin").json(&body).send().await.unwrap();
    assert_eq!(unknown.status(), reqwest::StatusCode::NOT_FOUND);
    h.state.database.as_ref().unwrap().lock().execute(
        "DELETE FROM project_members WHERE device_id = ?1", [owner.to_string()]).unwrap();
    // Revocation may already have closed the listener; either refusal or closure is required.
    if let Ok(response) = gateway.post(&endpoint).json(&body).send().await {
        assert_eq!(response.status(), reqwest::StatusCode::FORBIDDEN);
    }
    projects.terminal_close(&project.id, &terminal).unwrap();
    tokio::time::timeout(Duration::from_secs(3), async {
        while socket.exists() { tokio::time::sleep(Duration::from_millis(25)).await; }
    }).await.expect("gateway socket removed after revocation");
    server.abort();
}

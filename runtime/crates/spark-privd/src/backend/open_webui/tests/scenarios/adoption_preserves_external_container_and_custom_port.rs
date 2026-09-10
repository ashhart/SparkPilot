#[test]
fn adoption_preserves_external_container_and_custom_port() {
    let fixture = Fixture::new();
    let id = "f".repeat(64);
    let container = json!({"Id":id,"Name":"my-webui","Config":{"Image":"ghcr.io/open-webui/open-webui:main","Env":[]},"State":{"Running":true},"HostConfig":{"NetworkMode":"bridge"},"NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"9090"}]}},"Mounts":[{"Type":"bind","Source":"/owner/webui-data","Destination":"/app/backend/data"}]});
    fixture.docker.state.lock().unwrap().containers.insert(id.clone(), container.clone());
    let result = fixture.backend.execute(&PrivilegedOperation::InstallOpenWebUi {
        request_id: uuid::Uuid::new_v4(), image_digest: image('a'),
        admin_email: String::new(), admin_name: String::new(),
        admin_password: SecretString::new(""), gateway_api_key: SecretString::new(""),
        port: 9090, adopt_existing: true,
    }).unwrap();
    assert!(result.accepted);
    assert_eq!(fixture.backend.open_webui_port(), 9090);
    let status = fixture.backend.execute(&PrivilegedOperation::OpenWebUiStatus {request_id:uuid::Uuid::new_v4()}).unwrap();
    assert_eq!(status.details["adopted"], true);
    assert_eq!(status.details["healthy"], true);
    for operation in [
        PrivilegedOperation::RemoveOpenWebUi { request_id:uuid::Uuid::new_v4(), erase_data:true },
        PrivilegedOperation::UpdateOpenWebUi {request_id:uuid::Uuid::new_v4(), image_digest:image('c')},
        PrivilegedOperation::RepairOpenWebUi {request_id:uuid::Uuid::new_v4()},
    ] { assert!(fixture.backend.execute(&operation).is_err()); }
    // External updates invalidate the route, but must never prevent disconnecting it.
    fixture.docker.state.lock().unwrap().containers.get_mut(&id).unwrap()["Config"]["Image"] = json!("ghcr.io/open-webui/open-webui:new");
    let status = fixture.backend.execute(&PrivilegedOperation::OpenWebUiStatus {request_id:uuid::Uuid::new_v4()}).unwrap();
    assert_eq!(status.details["adopted"], true);
    assert_eq!(status.details["ownership_verified"], false);
    assert!(fixture.remove(false).accepted);
    let state = fixture.docker.state.lock().unwrap();
    assert!(state.containers.contains_key(&id));
    assert_eq!(state.containers[&id]["Mounts"],container["Mounts"]);
    assert!(state.calls.iter().all(|call| call[0] == "ps" || (call[0] == "container" && call[1] == "inspect")));
}

#[test]
fn managed_install_uses_the_selected_local_port() {
    let fixture = Fixture::new();
    let listener = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let result = fixture.backend.execute(&PrivilegedOperation::InstallOpenWebUi {
        request_id:uuid::Uuid::new_v4(), image_digest:image('a'),
        admin_email:"owner@example.test".into(),admin_name:"Owner".into(),
        admin_password:SecretString::new("local-webui-password"),gateway_api_key:SecretString::new("g".repeat(48)),
        port,adopt_existing:false,
    }).unwrap();
    assert!(result.accepted);
    assert_eq!(fixture.backend.open_webui_port(), port);
    let state = fixture.docker.state.lock().unwrap();
    for call in state.calls.iter().filter(|call| call[0] == "create") {
        assert!(call.contains(&format!("--env=PORT={port}")));
    }
}

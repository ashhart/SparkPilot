#[test]
fn recreated_same_name_volume_is_never_erased_or_reused() {
    let fixture = Fixture::new();
    fixture.install();
    let journal = fixture.backend.webui_load().unwrap().unwrap();
    let volume = journal.volume.unwrap();
    let displaced = volume.mountpoint.with_extension("preserved");
    fs::rename(&volume.mountpoint, displaced).unwrap();
    fs::create_dir(&volume.mountpoint).unwrap();
    assert_eq!(fixture.remove(true).code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.update().code, "OPEN_WEBUI_OWNERSHIP_UNVERIFIED");
    assert_eq!(fixture.docker.state.lock().unwrap().containers.len(), 1);
}

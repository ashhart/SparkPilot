struct SlowManifest {
    finished: Arc<std::sync::atomic::AtomicBool>,
}
impl sparkd::download::SourceResolver for SlowManifest {
    fn resolve(
        &self,
        _: &spark_models::ModelRecipe,
    ) -> Result<Vec<spark_models::RemoteFile>, String> {
        std::thread::sleep(Duration::from_millis(250));
        self.finished
            .store(true, std::sync::atomic::Ordering::SeqCst);
        Ok(Vec::new())
    }
}
struct NoDownload;
impl sparkd::download::FileSource for NoDownload {
    fn fetch(
        &self,
        _: &spark_models::ModelRecipe,
        _: &spark_models::RemoteFile,
        _: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        Err("preview must not download".into())
    }
}

#[tokio::test(flavor = "current_thread")]
async fn slow_install_evidence_does_not_block_runtime_timers() {
    for suffix in ["/preview", ""] {
        let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut peer = full_peer(false);
        peer.state = peer
            .state
            .with_download(sparkd::download::DownloadCoordinator {
                resolver: Box::new(SlowManifest {
                    finished: finished.clone(),
                }),
                source: Box::new(NoDownload),
            });
        let path = format!("/api/v1/models/example%2Fmodel-32b/install{suffix}");
        let request = signed_request(&peer, Method::POST, &path, b"{}");
        let response = router(peer.state).oneshot(request);
        let heartbeat = async {
            tokio::time::sleep(Duration::from_millis(10)).await;
            !finished.load(std::sync::atomic::Ordering::SeqCst)
        };
        let (response, responsive) = tokio::join!(response, heartbeat);
        assert!(response.is_ok());
        assert!(
            responsive,
            "{suffix}: manifest processing stalled the runtime heartbeat"
        );
    }
}

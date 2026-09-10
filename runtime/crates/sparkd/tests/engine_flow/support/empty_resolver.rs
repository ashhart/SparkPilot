struct EmptyResolver {
    starts: Arc<AtomicU64>,
}

impl sparkd::download::SourceResolver for EmptyResolver {
    fn resolve(&self, _recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String> {
        self.starts.fetch_add(1, Ordering::SeqCst);
        Ok(Vec::new())
    }
}

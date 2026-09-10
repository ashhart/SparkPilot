struct UnusedSource;

impl sparkd::download::FileSource for UnusedSource {
    fn fetch(
        &self,
        _recipe: &ModelRecipe,
        _file: &RemoteFile,
        _range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        Err("empty manifest must not fetch".into())
    }
}

use super::*;

#[derive(Debug)]
pub struct ModelInventory {
    pub recipes: Vec<ModelRecipe>,
    /// Allow unverified imports only through explicit policy.
    pub allow_unverified_import: bool,
}

/// Take one immutable catalogue snapshot per request so refresh cannot mix recipe generations within a decision.
pub struct LiveModelInventory {
    pub(super) current: parking_lot::RwLock<Arc<ModelInventory>>,
}

impl LiveModelInventory {
    pub fn new(current: Arc<ModelInventory>) -> Self {
        Self {
            current: parking_lot::RwLock::new(current),
        }
    }

    pub fn snapshot(&self) -> Arc<ModelInventory> {
        self.current.read().clone()
    }

    pub fn replace(&self, replacement: Arc<ModelInventory>) -> Arc<ModelInventory> {
        std::mem::replace(&mut *self.current.write(), replacement)
    }
}

impl ModelInventory {
    /// Verify live catalogues or promote the verified packaged bootstrap after trust rotation; missing development configuration yields an empty catalogue.
    pub fn from_catalogue(
        catalogue_path: Option<&Path>,
        root_key_path: Option<&Path>,
        bootstrap_path: Option<&Path>,
        allow_unverified_import: bool,
    ) -> Result<Arc<Self>, String> {
        let recipes = match (catalogue_path, root_key_path) {
            (Some(path), Some(root_path)) => {
                let root = load_root_key(root_path)?;
                Self::load_verified_or_bootstrap(path, bootstrap_path, &root)?
            }
            (Some(path), None) => return Err(format!("catalogue {path:?} requires a root key")),
            _ => Vec::new(),
        };
        Ok(Arc::new(Self {
            recipes,
            allow_unverified_import,
        }))
    }

    fn load_verified_or_bootstrap(
        live_path: &Path,
        bootstrap_path: Option<&Path>,
        root: &CatalogueRoot,
    ) -> Result<Vec<ModelRecipe>, String> {
        let live_error = match Self::load_verified(live_path, root) {
            Ok(recipes) => return Ok(recipes),
            Err(error) => error,
        };
        let Some(bootstrap_path) = bootstrap_path.filter(|path| path.exists()) else {
            return Err(live_error);
        };
        let recipes = Self::load_verified(bootstrap_path, root).map_err(|bootstrap_error| {
            format!(
                "live catalogue {live_path:?} rejected ({live_error}) and the packaged \
                 bootstrap {bootstrap_path:?} does not verify either ({bootstrap_error})"
            )
        })?;
        tracing::error!(
            live = %live_path.display(),
            bootstrap = %bootstrap_path.display(),
            reason = %live_error,
            "live catalogue rejected; serving the packaged bootstrap catalogue instead"
        );
        if let Err(error) = promote_bootstrap(bootstrap_path, live_path) {
            tracing::warn!(%error, "could not promote the bootstrap catalogue over the live copy");
        }
        Ok(recipes)
    }

    /// Load against a caller-supplied trust root (tests, tooling).
    pub fn from_catalogue_with_root(
        catalogue_path: &Path,
        root: CatalogueRoot,
        allow_unverified_import: bool,
    ) -> Result<Arc<Self>, String> {
        let recipes = Self::load_verified(catalogue_path, &root)?;
        Ok(Arc::new(Self {
            recipes,
            allow_unverified_import,
        }))
    }

    fn load_verified(path: &Path, root: &CatalogueRoot) -> Result<Vec<ModelRecipe>, String> {
        let catalogue: SignedCatalogue = load_catalogue(path, root).map_err(|e| e.to_string())?;
        catalogue
            .verified_recipes()
            .map_err(|e| e.to_string())
            .map(|r| r.to_vec())
    }

    pub fn recipe(&self, id: &str) -> Option<&ModelRecipe> {
        self.recipes.iter().find(|r| r.id() == id)
    }

    /// Materialise catalogue rows into the inventory DB (once, at startup).
    pub fn materialize(&self, conn: &rusqlite::Connection) -> Result<(), String> {
        for recipe in &self.recipes {
            crate::store::upsert_catalogue_model(conn, recipe).map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}

/// Atomically promote a same-directory bootstrap write so interrupted writes preserve the old live catalogue.
pub(super) fn promote_bootstrap(bootstrap_path: &Path, live_path: &Path) -> Result<(), String> {
    let bytes = std::fs::read(bootstrap_path).map_err(|error| error.to_string())?;
    let directory = live_path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", live_path.display()))?;
    std::fs::create_dir_all(directory).map_err(|error| error.to_string())?;
    let temporary = directory.join(format!(
        ".{}.{}.part",
        live_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| "catalogue.json".into()),
        uuid::Uuid::new_v4()
    ));
    std::fs::write(&temporary, &bytes).map_err(|error| error.to_string())?;
    std::fs::rename(&temporary, live_path).map_err(|error| {
        let _ = std::fs::remove_file(&temporary);
        error.to_string()
    })
}

pub fn load_root_key(path: &Path) -> Result<CatalogueRoot, String> {
    use std::io::Read as _;
    use std::os::unix::fs::OpenOptionsExt as _;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| e.to_string())?;
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() {
        return Err(format!(
            "catalogue root key must be a regular non-symlink file: {}",
            path.display()
        ));
    }
    let mut bytes = Vec::new();
    file.take(4097)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > 4096 {
        return Err("catalogue root key exceeds 4096 bytes".to_owned());
    }
    let key_bytes: [u8; 32] = {
        let text = String::from_utf8_lossy(&bytes).trim().to_owned();
        let decoded = hex::decode(text.trim()).map_err(|e| format!("root key hex: {e}"))?;
        decoded
            .try_into()
            .map_err(|_| "root key must be 32 bytes".to_string())?
    };
    use ed25519_dalek::VerifyingKey;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|e| format!("root key: {e}"))?;
    Ok(CatalogueRoot {
        // Use the lab catalogue root for local recipes; production promotion replaces this trust root.
        key_ids: vec!["catalogue-2026-b".into()],
        verifying_key: key,
    })
}

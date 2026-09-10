use super::*;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct KeyFile {
    pub(super) principal_id: Uuid,
    pub(super) generation: u64,
    pub(super) seed: String,
}

impl Drop for KeyFile {
    fn drop(&mut self) {
        self.seed.zeroize();
    }
}

pub struct RouterKey {
    pub principal_id: Uuid,
    pub generation: u64,
    pub(crate) signing: SigningKey,
}

pub struct RouterIdentityService {
    pub(super) directory: PathBuf,
    pub(super) lock: parking_lot::Mutex<()>,
}

impl RouterIdentityService {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            lock: parking_lot::Mutex::new(()),
        }
    }
    pub fn load(&self) -> Result<RouterKey, PoolError> {
        let _guard = self.lock.lock();
        self.load_inner()
    }
    fn validate_directory(&self) -> Result<(), PoolError> {
        let m = std::fs::symlink_metadata(&self.directory).map_err(io)?;
        if !m.is_dir()
            || m.permissions().mode() & 0o777 != 0o700
            || m.uid() != unsafe { libc::geteuid() }
        {
            return reject("POOL_ROUTER_KEY_UNAVAILABLE");
        }
        Ok(())
    }
    fn load_inner(&self) -> Result<RouterKey, PoolError> {
        self.validate_directory()?;
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.directory.join("request-key.json"))
            .map_err(io)?;
        let m = file.metadata().map_err(io)?;
        if !m.is_file()
            || m.len() > 4096
            || m.nlink() != 1
            || m.permissions().mode() & 0o777 != 0o600
            || m.uid() != unsafe { libc::geteuid() }
        {
            return reject("POOL_ROUTER_KEY_UNAVAILABLE");
        }
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        file.take(4097).read_to_end(&mut bytes).map_err(io)?;
        if bytes.len() > 4096 {
            return reject("POOL_ROUTER_KEY_UNAVAILABLE");
        }
        let doc: KeyFile = serde_json::from_slice(&bytes)
            .map_err(|_| PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE"))?;
        let seed = zeroize::Zeroizing::new(
            base64url_decode(&doc.seed)
                .map_err(|_| PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE"))?,
        );
        let signing = SigningKey::from_slice(&seed)
            .map_err(|_| PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE"))?;
        if doc.generation == 0 {
            return reject("POOL_ROUTER_KEY_UNAVAILABLE");
        }
        Ok(RouterKey {
            principal_id: doc.principal_id,
            generation: doc.generation,
            signing,
        })
    }
    pub fn prepare(
        &self,
        state: &AppState,
        expected: Option<&str>,
    ) -> Result<RouterIdentityDocument, PoolError> {
        let _guard = self.lock.lock();
        match std::fs::create_dir(&self.directory) {
            Ok(()) => {
                std::fs::set_permissions(&self.directory, std::fs::Permissions::from_mode(0o700))
                    .map_err(io)?
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(io(e)),
        };
        self.validate_directory()?;
        let path = self.directory.join("request-key.json");
        let current = if std::fs::symlink_metadata(&path).is_ok() {
            Some(self.load_inner()?)
        } else {
            None
        };
        let generation = match (current.as_ref(), expected) {
            (Some(key), None) => return key.document(state),
            (Some(key), Some(expected))
                if key.document(state)?.request_key_fingerprint == expected =>
            {
                key.generation
                    .checked_add(1)
                    .ok_or(PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE"))?
            }
            (None, None) => 1,
            _ => return reject("POOL_ROUTER_KEY_CHANGED"),
        };
        let signing = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let key = RouterKey {
            principal_id: Uuid::new_v4(),
            generation,
            signing,
        };
        let doc = KeyFile {
            principal_id: key.principal_id,
            generation,
            seed: base64url_encode(&key.signing.to_bytes()),
        };
        let bytes = zeroize::Zeroizing::new(serde_json::to_vec(&doc)?);
        let mut staged = tempfile::NamedTempFile::new_in(&self.directory).map_err(io)?;
        staged.write_all(&bytes).map_err(io)?;
        staged.as_file().sync_all().map_err(io)?;
        if current.is_some() {
            staged.persist(&path).map_err(|e| io(e.error))?;
        } else {
            staged.persist_noclobber(&path).map_err(|e| io(e.error))?;
        }
        std::fs::File::open(&self.directory)
            .and_then(|f| f.sync_all())
            .map_err(io)?;
        key.document(state)
    }
}

impl RouterKey {
    pub fn document(&self, state: &AppState) -> Result<RouterIdentityDocument, PoolError> {
        let der = self
            .signing
            .verifying_key()
            .to_public_key_der()
            .map_err(|_| PoolError::Refused("POOL_ROUTER_KEY_UNAVAILABLE"))?;
        let mut value = RouterIdentityDocument {
            protocol_version: 1,
            router_node_id: state.identity.node_id(),
            principal_id: self.principal_id,
            key_generation: self.generation,
            request_public_key_spki: base64url_encode(der.as_bytes()),
            request_key_fingerprint: sha256_hex(der.as_bytes()),
            authority_public_key: state.identity.public.authority_public_key.clone(),
            authority_fingerprint: state.identity.public.authority_fingerprint.clone(),
            authority_signature: String::new(),
        };
        value.authority_signature = base64url_encode(
            &state
                .identity
                .signing_key()
                .sign(&identity_message(&value)?)
                .to_bytes(),
        );
        Ok(value)
    }
}

pub(super) fn message(domain: &str, value: &impl Serialize) -> Result<Vec<u8>, PoolError> {
    let mut bytes = domain.as_bytes().to_vec();
    bytes.extend_from_slice(&serde_json::to_vec(value)?);
    Ok(bytes)
}

pub(super) fn identity_message(doc: &RouterIdentityDocument) -> Result<Vec<u8>, PoolError> {
    let mut doc = doc.clone();
    doc.authority_signature.clear();
    message("SPARK-POOL-IDENTITY-1\n", &doc)
}

pub fn challenge_message(challenge: &RouterEnrollmentChallenge) -> Result<Vec<u8>, PoolError> {
    let mut c = challenge.clone();
    c.recipient_authority_signature.clear();
    message("SPARK-POOL-ENROLL-1\n", &c)
}

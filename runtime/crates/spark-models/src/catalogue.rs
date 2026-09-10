//! Retain the last valid catalogue when offline and reject invalid signatures without a verification fallback.

use std::path::Path;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::recipe::ModelRecipe;
use crate::verify::{CatalogueRoot, VerifyError};

#[derive(Debug, Error)]
pub enum CatalogueError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("catalogue signature verification failed: {0}")]
    Signature(#[from] VerifyError),
    #[error("catalogue has no recipes")]
    Empty,
}

/// Sign the canonical ordered recipes array with Ed25519 inside the snapshot envelope.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignedCatalogue {
    pub recipes: Vec<ModelRecipe>,
    pub signature: CatalogueSignature,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CatalogueSignature {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub algorithm: String,
    pub value: String,
}

impl SignedCatalogue {
    /// Sign compact JSON of recipes in their existing order, excluding the envelope signature.
    pub fn canonical_entries(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&self.recipes)
    }

    /// Verify snapshot authority and structural validity of every signed member recipe.
    pub fn verify(&self, root: &CatalogueRoot) -> Result<(), CatalogueError> {
        if !root.key_ids.contains(&self.signature.key_id) {
            return Err(VerifyError::UnknownKeyId(self.signature.key_id.clone()).into());
        }
        let canonical = self.canonical_entries()?;
        root.verify_bytes(&canonical, &self.signature.algorithm, &self.signature.value)?;
        for recipe in &self.recipes {
            recipe
                .validate()
                .map_err(|e| VerifyError::InvalidRecipe(e.to_string()))?;
            root.verify_recipe(recipe)?;
        }
        Ok(())
    }

    /// Reject an empty catalogue and return only structurally verified recipes.
    pub fn verified_recipes(&self) -> Result<&[ModelRecipe], CatalogueError> {
        if self.recipes.is_empty() {
            return Err(CatalogueError::Empty);
        }
        Ok(&self.recipes)
    }
}

/// Open catalogue trust files without following final symlinks and verify content consistently across all readers.
pub fn load_catalogue(
    path: &Path,
    root: &CatalogueRoot,
) -> Result<SignedCatalogue, CatalogueError> {
    let bytes = {
        use std::io::Read;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes)?;
        bytes
    };
    let catalogue: SignedCatalogue = serde_json::from_slice(&bytes)?;
    catalogue.verify(root)?;
    Ok(catalogue)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recipe::fixture::RecipeFixture;
    use crate::recipe::{KvCacheDtype, MambaCacheMode};
    use crate::verify::testkit;
    use ed25519_dalek::SigningKey;

    fn signed_envelope(seed: &[u8; 32]) -> SignedCatalogue {
        let mut recipe = RecipeFixture::example();
        testkit::sign_recipe(&mut recipe, &SigningKey::from_bytes(seed));
        // Sign exactly what `canonical_entries` re-derives at verify time.
        let mut envelope = SignedCatalogue {
            recipes: vec![recipe.clone()],
            signature: CatalogueSignature {
                key_id: "catalogue-test".into(),
                algorithm: "ed25519".into(),
                value: String::new(),
            },
        };
        let canonical = envelope.canonical_entries().expect("recipe serialization");
        envelope.signature.value = testkit::sign_bytes(&canonical, &SigningKey::from_bytes(seed));
        envelope
    }

    #[test]
    fn valid_catalogue_verifies() {
        let seed = [11u8; 32];
        let root = CatalogueRoot::from_seed(&seed);
        let catalogue = signed_envelope(&seed);
        catalogue.verify(&root).expect("catalogue verifies");
        assert_eq!(catalogue.verified_recipes().unwrap().len(), 1);
    }

    #[test]
    fn tampered_catalogue_entry_rejected() {
        let seed = [12u8; 32];
        let mut catalogue = signed_envelope(&seed);
        catalogue.recipes[0].memory.expected_weight_bytes += 4096;
        let root = CatalogueRoot::from_seed(&seed);
        assert!(matches!(
            catalogue.verify(&root),
            Err(CatalogueError::Signature(_))
        ));
    }

    #[test]
    fn wrong_root_rejected() {
        let seed = [13u8; 32];
        let catalogue = signed_envelope(&seed);
        let other_root = CatalogueRoot::from_seed(&[14u8; 32]);
        assert!(matches!(
            catalogue.verify(&other_root),
            Err(CatalogueError::Signature(_))
        ));
    }

    #[test]
    fn packaged_lab_bootstrap_is_signed_pinned_and_nonempty() {
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let root_hex =
            std::fs::read_to_string(repository.join("packaging/trust/catalogue-root.pub")).unwrap();
        let key_bytes: [u8; 32] = hex::decode(root_hex.trim()).unwrap().try_into().unwrap();
        let root = CatalogueRoot {
            key_ids: vec!["catalogue-2026-b".into()],
            verifying_key: ed25519_dalek::VerifyingKey::from_bytes(&key_bytes).unwrap(),
        };
        let catalogue = load_catalogue(
            &repository.join("packaging/catalogue/bootstrap.lab.json"),
            &root,
        )
        .unwrap();
        let recipes = catalogue.verified_recipes().unwrap();
        assert_eq!(recipes.len(), 2);
        let mut recipes = recipes.to_vec();
        recipes.sort_by_key(|recipe| recipe.uses_qwen38_preparation());
        assert!(recipes[1].uses_qwen38_preparation());
        assert_eq!(recipes[1].profiles[0].max_model_length, 262_144);
        assert_eq!(
            recipes[1].source.revision,
            "925d7be6c14c6c9442ef83e8f05b5a3c39304f69"
        );
        assert_eq!(
            recipes[0].id(),
            "nvidia/nemotron-3.5-lightning-30b-a3b-nvfp4"
        );
        let standalone: ModelRecipe = serde_json::from_slice(
            &std::fs::read(
                repository.join("recipes/nvidia-nemotron-3.5-lightning-30b-a3b-nvfp4.json"),
            )
            .unwrap(),
        )
        .unwrap();
        root.verify_recipe(&standalone).unwrap();
        assert_eq!(
            serde_json::to_value(&standalone).unwrap(),
            serde_json::to_value(&recipes[0]).unwrap(),
            "the standalone recipe must exactly match its signed catalogue entry"
        );
        assert_eq!(
            recipes[0].source.revision,
            "cc84af2fe71647d87f4486c064f320e1e7535243"
        );
        // Pin the linux/arm64 image manifest because an amd64-only digest cannot run on a DGX Spark.
        assert_eq!(
            recipes[0].engine.image,
            "vllm/vllm-openai@sha256:2a7cde230b59f3ce6cab33dd245ba6bee41aa87b38c9fe84f966ff24016813ce"
        );
        let options = recipes[0].engine.options.as_ref().expect("engine options");
        assert_eq!(options.mamba_cache_mode, Some(MambaCacheMode::Align));
        assert_eq!(options.kv_cache_dtype, Some(KvCacheDtype::Fp8));
        assert_eq!(
            options.tool_call_parser,
            Some(crate::recipe::ToolCallParser::Qwen3Coder)
        );
        assert_eq!(
            recipes[0]
                .metadata
                .recipe_source
                .as_ref()
                .map(|source| source.name.as_str()),
            Some("vLLM Recipes")
        );
        assert!(recipes[0].engine.image.contains("@sha256:"));
        assert!(!recipes[0].engine.image.ends_with(&"0".repeat(64)));
        assert!(!recipes[0].source.trust_remote_code);
    }
}

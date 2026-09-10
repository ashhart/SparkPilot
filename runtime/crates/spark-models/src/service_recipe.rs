//! Sign optional-service plans containing one pinned container, one loopback listener and an allowlisted local inference gateway.

use base64::Engine as _;
use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};
use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const DEFAULT_OPEN_WEBUI_RECIPE_PATH: &str =
    "/usr/share/spark-runtime/services/open-webui.service.json";
pub const DEFAULT_SERVICE_ROOT_PATH: &str = "/usr/share/spark-runtime/trust/service-root.pub";

#[derive(Debug, Error)]
pub enum ServiceRecipeError {
    #[error("service recipe material is unavailable: {0}")]
    Io(#[from] std::io::Error),
    #[error("service recipe JSON is invalid: {0}")]
    Json(#[from] serde_json::Error),
    #[error("service recipe trust root is invalid")]
    TrustRoot,
    #[error("service recipe signature is invalid")]
    Signature,
    #[error("service recipe violates policy: {0}")]
    Policy(&'static str),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceMetadata {
    pub id: String,
    pub revision: String,
    pub display_name: String,
    pub publisher: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceContainer {
    pub image: String,
    pub version: String,
    pub internal_port: u16,
    pub loopback_port: u16,
    pub data_volume: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceGateway {
    #[serde(rename = "baseURL")]
    pub base_url: String,
    pub scopes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceSecurity {
    pub loopback_only: bool,
    pub network_mode: String,
    pub read_only_root: bool,
    pub drop_all_capabilities: bool,
    pub no_new_privileges: bool,
    pub signup_disabled_after_bootstrap: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceRecipeSignature {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub algorithm: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ServiceRecipe {
    pub api_version: String,
    pub kind: String,
    pub metadata: ServiceMetadata,
    pub container: ServiceContainer,
    pub gateway: ServiceGateway,
    pub security: ServiceSecurity,
    pub signature: ServiceRecipeSignature,
}

impl ServiceRecipe {
    pub fn canonical_without_signature(&self) -> Result<Vec<u8>, serde_json::Error> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Canonical<'a> {
            api_version: &'a str,
            kind: &'a str,
            metadata: &'a ServiceMetadata,
            container: &'a ServiceContainer,
            gateway: &'a ServiceGateway,
            security: &'a ServiceSecurity,
        }
        serde_json::to_vec(&Canonical {
            api_version: &self.api_version,
            kind: &self.kind,
            metadata: &self.metadata,
            container: &self.container,
            gateway: &self.gateway,
            security: &self.security,
        })
    }

    pub fn verify(&self, public_key_hex: &str) -> Result<(), ServiceRecipeError> {
        self.validate()?;
        if self.signature.key_id != "service-2026-a" || self.signature.algorithm != "ed25519" {
            return Err(ServiceRecipeError::Signature);
        }
        let public_key: [u8; 32] = hex::decode(public_key_hex.trim())
            .map_err(|_| ServiceRecipeError::TrustRoot)?
            .try_into()
            .map_err(|_| ServiceRecipeError::TrustRoot)?;
        let key =
            VerifyingKey::from_bytes(&public_key).map_err(|_| ServiceRecipeError::TrustRoot)?;
        let signature_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&self.signature.value)
            .map_err(|_| ServiceRecipeError::Signature)?;
        let signature =
            Signature::from_slice(&signature_bytes).map_err(|_| ServiceRecipeError::Signature)?;
        key.verify(&self.canonical_without_signature()?, &signature)
            .map_err(|_| ServiceRecipeError::Signature)
    }

    fn validate(&self) -> Result<(), ServiceRecipeError> {
        if self.api_version != "spark.runtime/v1" || self.kind != "ServiceRecipe" {
            return Err(ServiceRecipeError::Policy("wrong apiVersion or kind"));
        }
        if self.metadata.id != "open-webui" {
            return Err(ServiceRecipeError::Policy("service id is not allowlisted"));
        }
        let Some((repository, digest)) = self.container.image.rsplit_once("@sha256:") else {
            return Err(ServiceRecipeError::Policy("image is not digest pinned"));
        };
        if repository != "ghcr.io/open-webui/open-webui"
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            || digest.bytes().all(|byte| byte == b'0')
        {
            return Err(ServiceRecipeError::Policy(
                "image is outside the Open WebUI allowlist",
            ));
        }
        if self.container.internal_port != 8080
            || self.container.loopback_port != 18080
            || self.container.data_volume != "spark-open-webui-data"
            || self.gateway.base_url != "http://127.0.0.1:18081/v1"
            || self.gateway.scopes != ["models.read", "chat.completions.create"]
        {
            return Err(ServiceRecipeError::Policy(
                "service ports or gateway scopes changed",
            ));
        }
        let security = &self.security;
        if !(security.loopback_only
            && security.network_mode == "host"
            && security.read_only_root
            && security.drop_all_capabilities
            && security.no_new_privileges
            && security.signup_disabled_after_bootstrap)
        {
            return Err(ServiceRecipeError::Policy("required isolation is missing"));
        }
        Ok(())
    }
}

pub fn bundled_open_webui_recipe() -> Result<ServiceRecipe, ServiceRecipeError> {
    let recipe: ServiceRecipe = serde_json::from_slice(include_bytes!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../recipes/open-webui.service.json"
    )))?;
    recipe.verify(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../packaging/trust/service-root.pub"
    )))?;
    Ok(recipe)
}

/// Load and verify package recipe material; any error makes the optional service unavailable.
pub fn load_open_webui_recipe(
    recipe_path: &std::path::Path,
    trust_root_path: &std::path::Path,
) -> Result<ServiceRecipe, ServiceRecipeError> {
    let recipe: ServiceRecipe = serde_json::from_slice(&std::fs::read(recipe_path)?)?;
    let trust_root = std::fs::read_to_string(trust_root_path)?;
    recipe.verify(&trust_root)?;
    Ok(recipe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_recipe_is_signed_pinned_and_isolated() {
        let recipe = bundled_open_webui_recipe().expect("bundled recipe verifies");
        assert_eq!(recipe.metadata.id, "open-webui");
        assert!(recipe.container.image.contains("@sha256:"));
        assert!(recipe.security.loopback_only);
        assert_eq!(recipe.gateway.scopes.len(), 2);
    }

    #[test]
    fn tampering_is_rejected() {
        let mut recipe = bundled_open_webui_recipe().unwrap();
        recipe.container.image = "ghcr.io/open-webui/open-webui@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into();
        assert!(matches!(
            recipe.verify(include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../packaging/trust/service-root.pub"
            ))),
            Err(ServiceRecipeError::Signature)
        ));
    }

    #[test]
    fn installed_recipe_loader_fails_closed_for_missing_or_invalid_material() {
        let directory = tempfile::tempdir().unwrap();
        let recipe_path = directory.path().join("open-webui.service.json");
        let root_path = directory.path().join("service-root.pub");
        assert!(matches!(
            load_open_webui_recipe(&recipe_path, &root_path),
            Err(ServiceRecipeError::Io(_))
        ));

        std::fs::write(
            &recipe_path,
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../../recipes/open-webui.service.json"
            )),
        )
        .unwrap();
        std::fs::write(&root_path, "not-a-public-key\n").unwrap();
        assert!(matches!(
            load_open_webui_recipe(&recipe_path, &root_path),
            Err(ServiceRecipeError::TrustRoot)
        ));
    }
}

//! Sign catalogues offline using an external 32-byte private-key file that never enters output or logs.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use clap::Parser;
use ed25519_dalek::{Signer, SigningKey};
use spark_models::catalogue::{CatalogueSignature, SignedCatalogue};
use spark_models::recipe::ModelRecipe;

#[derive(Debug, Parser)]
struct Arguments {
    #[arg(long, required = true)]
    recipe: Vec<PathBuf>,
    #[arg(long)]
    key: PathBuf,
    #[arg(long)]
    key_id: String,
    #[arg(long)]
    output: PathBuf,
    #[arg(long)]
    public_key_output: PathBuf,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let arguments = Arguments::parse();
    if arguments.key_id.trim().is_empty() {
        return Err("key id must not be empty".into());
    }

    let metadata = fs::metadata(&arguments.key)?;
    if metadata.mode() & 0o077 != 0 {
        return Err(format!(
            "{} is group/world accessible; signing keys must be mode 0600",
            arguments.key.display()
        )
        .into());
    }
    let seed: [u8; 32] = fs::read(&arguments.key)?
        .try_into()
        .map_err(|_| "signing key must contain exactly 32 raw bytes")?;
    let signing_key = SigningKey::from_bytes(&seed);

    let mut recipes = Vec::with_capacity(arguments.recipe.len());
    for path in &arguments.recipe {
        let mut recipe: ModelRecipe = serde_json::from_slice(&fs::read(path)?)?;
        recipe.signature.key_id = arguments.key_id.clone();
        recipe.signature.algorithm = "ed25519".into();
        recipe.signature.value = URL_SAFE_NO_PAD.encode(
            signing_key
                .sign(&recipe.canonical_without_signature()?)
                .to_bytes(),
        );
        recipe.validate()?;
        recipes.push(recipe);
    }

    let mut catalogue = SignedCatalogue {
        recipes,
        signature: CatalogueSignature {
            key_id: arguments.key_id,
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    catalogue.signature.value =
        URL_SAFE_NO_PAD.encode(signing_key.sign(&catalogue.canonical_entries()?).to_bytes());

    write_new(
        &arguments.output,
        &serde_json::to_vec_pretty(&catalogue)?,
        0o644,
    )?;
    write_new(
        &arguments.public_key_output,
        hex::encode(signing_key.verifying_key().to_bytes()).as_bytes(),
        0o644,
    )?;
    println!(
        "signed {} recipe(s) into {} with {}",
        catalogue.recipes.len(),
        arguments.output.display(),
        catalogue.signature.key_id
    );
    Ok(())
}

fn write_new(path: &Path, bytes: &[u8], mode: u32) -> Result<(), std::io::Error> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)?;
    file.write_all(bytes)?;
    file.write_all(b"\n")?;
    file.sync_all()
}

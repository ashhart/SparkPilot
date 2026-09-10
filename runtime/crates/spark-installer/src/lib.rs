//! Verify signed releases and prepare identity, schema, protected state directories and first-owner bootstrap.

pub mod bootstrap;
pub mod manifest;
pub mod state;
pub mod trust;
pub mod verify;

pub const INSTALL_SCRIPT_NAME: &str = "spark-installer";

pub use bootstrap::{
    BootstrapReport, PrepareReport, SchemaReport, bootstrap_owner, prepare, schema_report,
};
pub use manifest::{ReleaseArtifact, ReleaseManifest};
pub use state::{CatalogueSeedReport, StateReport, prepare as prepare_state, seed_catalogue};
pub use trust::{ReleaseTrustRoot, VerifiedManifest};
pub use verify::{
    ArtifactVerification, TrustRootSource, VerificationReport, verify_artifact, verify_release,
};

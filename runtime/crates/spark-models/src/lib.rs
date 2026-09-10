//! Provide signed, pinned model catalogue and recipe types with memory-fit estimates.

pub mod catalogue;
pub mod fit;
pub mod recipe;
pub mod reservation;
pub mod service_recipe;
pub mod verify;

pub use catalogue::{SignedCatalogue, load_catalogue};
pub use fit::{FitState, compute_fit};
pub use recipe::{ModelRecipe, Profile, RecipeError, RemoteFile};
pub use reservation::MemoryReservation;
pub use verify::{CatalogueRoot, VerifyError};

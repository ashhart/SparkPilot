/// Reverify against the immutable installed trust root without a caller-supplied alternative.
pub const INSTALLED_TRUST_ROOT: &str = "/usr/share/spark-runtime/trust/release-keys.json";

/// Compose staging paths only from validated release IDs beneath this fixed root.
pub const DEFAULT_STAGING_ROOT: &str = "/var/cache/spark-runtime/updates";

/// Keep seals and commit records in the helper's private systemd StateDirectory, writable within its strict filesystem sandbox.
pub const DEFAULT_STATE_ROOT: &str = "/var/lib/spark-privd/updates";

/// The fixed installer binary used to re-verify at the privileged boundary.
pub const INSTALLER_BIN: &str = "/usr/lib/spark-runtime/spark-installer";

/// The fixed package manager binary. `dpkg -i <sealed deb>` and nothing else.
pub const DPKG_BIN: &str = "/usr/bin/dpkg";

/// The only program the privileged request handler executes for an update.
pub const SYSTEMCTL_BIN: &str = "/usr/bin/systemctl";

/// The sparkd daemon path whose presence means the runtime is not quiescent.
pub const SPARKD_BIN: &str = "/usr/lib/spark-runtime/sparkd";

/// Require one safe release-ID path component beginning with a lowercase letter.
pub const RELEASE_ID_MIN: usize = 2;

pub const RELEASE_ID_MAX: usize = 128;

/// Bound every staged input before verification; the verifier independently checks package size.
pub const MAX_MANIFEST_BYTES: u64 = 1 << 20;

pub const MAX_SIGNATURE_BYTES: u64 = 1 << 20;

pub const MAX_PACKAGE_BYTES: u64 = 4 << 30;

/// Bound verifier-report bytes before parsing.
pub const MAX_VERIFY_REPORT_BYTES: usize = 1 << 20;

/// The fixed file names the helper reads from staging and writes to its seal.
pub const STAGED_MANIFEST: &str = "manifest.json";

pub const STAGED_PACKAGE: &str = "package.deb";

pub const STAGED_SIGNATURE: &str = "package.deb.sig";

/// Retained "currently committed" package file names.
pub const RETAINED_MANIFEST: &str = "current.manifest.json";

pub const RETAINED_PACKAGE: &str = "current.deb";

pub const RETAINED_SIGNATURE: &str = "current.deb.sig";

/// Root-owned hand-off marker consumed by the detached worker.
pub const SCHEDULED_RELEASE: &str = "scheduled-release-id";

/// Persist terminal outcomes for daemon reconciliation after package installation restarts the services.
pub const UPDATE_STATUS_DIRECTORY: &str = "outcomes";

pub(super) const MAX_UPDATE_STATUS_BYTES: u64 = 1 << 20;

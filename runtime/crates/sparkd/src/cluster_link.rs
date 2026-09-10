//! Discover ConnectX by PCI vendor and validate carrier, MTU and speed; run container-based collective checks through the privileged helper.

use std::path::{Path, PathBuf};

use crate::cluster::{ClusterError, CollectiveOutcome, CollectiveTesting, LinkProbing, LinkReport};

/// PCI vendor id for Mellanox / NVIDIA Networking (ConnectX).
const CONNECTX_VENDOR: &str = "0x15b3";
/// Minimum negotiated link speed, in Mb/s, for the 200 GbE QSFP fabric.
const MINIMUM_LINK_MBPS: u64 = 200_000;
/// Jumbo frames are required for NCCL throughput on this fabric.
const MINIMUM_MTU: u32 = 9000;

/// Link probe over `/sys/class/net`.
pub struct SysfsLinkProbe {
    root: PathBuf,
}

impl Default for SysfsLinkProbe {
    fn default() -> Self {
        Self {
            root: PathBuf::from("/sys/class/net"),
        }
    }
}

impl SysfsLinkProbe {
    pub fn with_root(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Report unavailable probing when sysfs is absent rather than inventing inspected link evidence.
    pub fn available(&self) -> bool {
        self.root.is_dir()
    }

    fn read_trimmed(directory: &Path, name: &str) -> Option<String> {
        std::fs::read_to_string(directory.join(name))
            .ok()
            .map(|value| value.trim().to_owned())
    }

    /// Candidate ConnectX interfaces, in stable name order.
    fn candidates(&self) -> Result<Vec<PathBuf>, ClusterError> {
        let entries = std::fs::read_dir(&self.root)
            .map_err(|error| ClusterError::LinkUnhealthy(format!("reading interfaces: {error}")))?;
        let mut candidates: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|directory| {
                Self::read_trimmed(directory, "device/vendor").as_deref() == Some(CONNECTX_VENDOR)
            })
            .collect();
        candidates.sort();
        Ok(candidates)
    }
}

impl LinkProbing for SysfsLinkProbe {
    fn probe(&self) -> Result<LinkReport, ClusterError> {
        if !self.available() {
            return Err(ClusterError::LinkUnhealthy(
                "this host exposes no /sys/class/net; the cluster link cannot be examined".into(),
            ));
        }
        let candidates = self.candidates()?;
        if candidates.is_empty() {
            return Err(ClusterError::LinkUnhealthy(
                "no ConnectX (vendor 0x15b3) interface is present".into(),
            ));
        }

        // Prefer a connected port so an unplugged sibling does not hide a usable fabric link.
        let mut best: Option<LinkReport> = None;
        for directory in candidates {
            let name = directory
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let link_up = Self::read_trimmed(&directory, "carrier").as_deref() == Some("1")
                && Self::read_trimmed(&directory, "operstate").as_deref() == Some("up");
            let mtu = Self::read_trimmed(&directory, "mtu")
                .and_then(|value| value.parse::<u32>().ok())
                .unwrap_or(0);
            // Treat speed read errors and -1 as an unnegotiated link.
            let speed = Self::read_trimmed(&directory, "speed")
                .and_then(|value| value.parse::<i64>().ok())
                .filter(|speed| *speed > 0)
                .unwrap_or(0) as u64;
            let report = LinkReport {
                interface: name,
                link_up,
                mtu,
                bandwidth_gbitps_ok: speed >= MINIMUM_LINK_MBPS && mtu >= MINIMUM_MTU,
            };
            let better = match &best {
                None => true,
                Some(current) => {
                    (report.link_up, report.bandwidth_gbitps_ok)
                        > (current.link_up, current.bandwidth_gbitps_ok)
                }
            };
            if better {
                best = Some(report);
            }
        }
        best.ok_or_else(|| {
            ClusterError::LinkUnhealthy("no ConnectX interface could be read".into())
        })
    }
}

/// Run ray status through the helper using the configured pinned engine image.
pub struct PrivilegedCollectiveTest {
    client: crate::privd::PrivilegedClient,
    /// Without a configured collective image, report skipped validation and degraded readiness.
    image_digest: Option<String>,
}

impl PrivilegedCollectiveTest {
    pub fn new(client: crate::privd::PrivilegedClient, image_digest: Option<String>) -> Self {
        Self {
            client,
            image_digest,
        }
    }
}

impl CollectiveTesting for PrivilegedCollectiveTest {
    fn run(&self) -> Result<CollectiveOutcome, ClusterError> {
        use spark_privd::protocol::PrivilegedOperation;
        let Some(image_digest) = self.image_digest.clone() else {
            tracing::warn!(
                "no [cluster] collective_image_digest is configured; the collective test \
                 cannot run and the cluster will report degraded"
            );
            return Ok(CollectiveOutcome::Skipped);
        };
        let response = self
            .client
            .call(PrivilegedOperation::RunClusterCollectiveTest {
                request_id: uuid::Uuid::new_v4(),
                image_digest,
            })
            .map_err(|error| ClusterError::CollectiveTestFailed(error.to_string()))?;
        if !response.accepted {
            return Err(ClusterError::CollectiveTestFailed(format!(
                "{}: {}",
                response.code, response.message
            )));
        }
        match response
            .details
            .get("outcome")
            .and_then(serde_json::Value::as_str)
        {
            Some("passed") => Ok(CollectiveOutcome::Passed),
            Some("failed") => Ok(CollectiveOutcome::Failed),
            // Map unavailable collective execution to degraded readiness rather than claiming validation passed.
            Some("skipped") => Ok(CollectiveOutcome::Skipped),
            other => Err(ClusterError::CollectiveTestFailed(format!(
                "helper reported an unknown outcome: {other:?}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn interface(
        root: &Path,
        name: &str,
        vendor: &str,
        carrier: &str,
        operstate: &str,
        mtu: &str,
        speed: &str,
    ) {
        let directory = root.join(name);
        std::fs::create_dir_all(directory.join("device")).unwrap();
        std::fs::write(directory.join("device/vendor"), vendor).unwrap();
        std::fs::write(directory.join("carrier"), carrier).unwrap();
        std::fs::write(directory.join("operstate"), operstate).unwrap();
        std::fs::write(directory.join("mtu"), mtu).unwrap();
        std::fs::write(directory.join("speed"), speed).unwrap();
    }

    #[test]
    fn the_connectx_interface_is_discovered_rather_than_named() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        // Reject other vendors regardless of plausible interface names.
        interface(root, "enp1s0f1np1", "0x8086", "1", "up", "9000", "200000");
        interface(root, "ibp5s0", "0x15b3", "1", "up", "9000", "200000");

        let probe = SysfsLinkProbe::with_root(root);
        let report = probe.probe().unwrap();
        assert_eq!(report.interface, "ibp5s0");
        assert!(report.link_up);
        assert_eq!(report.mtu, 9000);
        assert!(report.bandwidth_gbitps_ok);
    }

    #[test]
    fn a_cable_that_negotiated_too_slowly_fails_the_bandwidth_check() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        interface(root, "ibp5s0", "0x15b3", "1", "up", "9000", "100000");
        let report = SysfsLinkProbe::with_root(root).probe().unwrap();
        assert!(report.link_up, "the link is up, just slow");
        assert!(
            !report.bandwidth_gbitps_ok,
            "a QSFP fabric link below 200 Gb/s must not be accepted as healthy"
        );

        // Jumbo frames matter as much as raw speed for NCCL throughput.
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        interface(root, "ibp5s0", "0x15b3", "1", "up", "1500", "200000");
        let report = SysfsLinkProbe::with_root(root).probe().unwrap();
        assert!(!report.bandwidth_gbitps_ok, "1500-byte MTU must not pass");
    }

    #[test]
    fn the_port_with_a_cable_in_it_is_preferred() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        // Prefer the connected QSFP port when its sibling is unplugged.
        interface(root, "ibp5s0", "0x15b3", "0", "down", "9000", "-1");
        interface(root, "ibp5s1", "0x15b3", "1", "up", "9000", "200000");
        let report = SysfsLinkProbe::with_root(root).probe().unwrap();
        assert_eq!(report.interface, "ibp5s1");
        assert!(report.link_up && report.bandwidth_gbitps_ok);
    }

    #[test]
    fn an_absent_cable_or_adapter_is_reported_not_guessed() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        // Missing ConnectX hardware must not produce healthy link evidence.
        interface(root, "eth0", "0x8086", "1", "up", "1500", "10000");
        let error = SysfsLinkProbe::with_root(root)
            .probe()
            .expect_err("no ConnectX present");
        assert!(matches!(error, ClusterError::LinkUnhealthy(_)));

        // Carrier is required even when the interface exists.
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path();
        interface(root, "ibp5s0", "0x15b3", "0", "down", "9000", "-1");
        let report = SysfsLinkProbe::with_root(root).probe().unwrap();
        assert!(!report.link_up);
        assert!(!report.bandwidth_gbitps_ok);

        // A host with no sysfs at all fails closed rather than pretending.
        let probe = SysfsLinkProbe::with_root("/nonexistent/class/net");
        assert!(!probe.available());
        assert!(matches!(probe.probe(), Err(ClusterError::LinkUnhealthy(_))));
    }
}

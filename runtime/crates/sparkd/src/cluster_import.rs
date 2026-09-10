//! Read-only import of clusters configured outside Spark Runtime.

use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

use crate::cluster::ClusterError;

pub const EXTERNALLY_CONFIGURED: &str = "externally_configured";

/// Authenticate fabric peers through the trusted challenge; carrier, routes, MACs and configuration provenance are observation only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FabricProofSource {
    MutualTlsChallenge,
}

impl FabricProofSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::MutualTlsChallenge => "mutual_tls_challenge",
        }
    }
}

/// Store a directed trusted challenge result without exposing an HTTP write route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FabricPeerProof {
    pub observer_node_id: String,
    pub observer_port_id: String,
    pub peer_node_id: String,
    pub peer_port_id: Option<String>,
    pub verified_at: String,
    pub expires_at: String,
    pub source: FabricProofSource,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExternalImportMember {
    pub node_id: String,
    pub name: Option<String>,
    pub identity_authenticated: bool,
    pub identity_source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AuthenticatedFabricLink {
    pub member_a_node_id: String,
    pub member_a_port_id: String,
    pub member_b_node_id: String,
    pub member_b_port_id: String,
    pub proof_source: String,
    pub path_topology: String,
    pub direct_connection_proven: bool,
    pub verified_at: String,
    pub expires_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExternalImportBlocker {
    pub code: String,
    pub member_node_id: Option<String>,
}

/// Keep import registration unavailable until coordination can install signed membership on every member atomically.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExternalClusterImportPreview {
    pub name: String,
    pub configuration_owner: String,
    pub members: Vec<ExternalImportMember>,
    pub authenticated_links: Vec<AuthenticatedFabricLink>,
    pub evidence_complete: bool,
    pub registration_available: bool,
    pub automatic_topology_available: bool,
    pub takeover_available: bool,
    pub blockers: Vec<ExternalImportBlocker>,
    pub preservation_guarantees: Vec<String>,
}

/// Record only challenges bound to both identities over verified mutual TLS; import preview also requires reciprocal peer evidence.
pub fn record_fabric_peer_proof(
    conn: &Connection,
    proof: &FabricPeerProof,
) -> Result<(), ClusterError> {
    for node_id in [&proof.observer_node_id, &proof.peer_node_id] {
        if uuid::Uuid::parse_str(node_id).is_err() {
            return Err(ClusterError::InvalidFabricProof(
                "fabric proof node IDs must be UUIDs".into(),
            ));
        }
        let known: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM peer_facts WHERE node_id = ?1)",
            [node_id],
            |row| row.get(0),
        )?;
        if !known {
            return Err(ClusterError::UnknownPeer((*node_id).clone()));
        }
    }
    if proof.observer_node_id == proof.peer_node_id {
        return Err(ClusterError::InvalidFabricProof(
            "observer and peer must differ".into(),
        ));
    }
    for (label, value) in [
        ("observer port", Some(proof.observer_port_id.as_str())),
        ("peer port", proof.peer_port_id.as_deref()),
    ] {
        if value.is_some_and(|value| value.is_empty() || value.len() > 128) {
            return Err(ClusterError::InvalidFabricProof(format!(
                "{label} must contain between 1 and 128 characters"
            )));
        }
    }
    let parse_timestamp = |label: &str, value: &str| {
        time::OffsetDateTime::parse(value, &time::format_description::well_known::Rfc3339)
            .map_err(|_| ClusterError::InvalidFabricProof(format!("{label} is not RFC3339")))
    };
    let verified_at = parse_timestamp("verified_at", &proof.verified_at)?;
    let expires_at = parse_timestamp("expires_at", &proof.expires_at)?;
    if expires_at <= verified_at {
        return Err(ClusterError::InvalidFabricProof(
            "expires_at must be later than verified_at".into(),
        ));
    }

    conn.execute(
        "INSERT INTO fabric_peer_proofs
            (observer_node_id, observer_port_id, peer_node_id, peer_port_id,
             verified_at, expires_at, source)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(observer_node_id, observer_port_id, peer_node_id) DO UPDATE SET
            peer_port_id = excluded.peer_port_id,
            verified_at = excluded.verified_at,
            expires_at = excluded.expires_at,
            source = excluded.source",
        rusqlite::params![
            proof.observer_node_id,
            proof.observer_port_id,
            proof.peer_node_id,
            proof.peer_port_id,
            proof.verified_at,
            proof.expires_at,
            proof.source.as_str(),
        ],
    )?;
    Ok(())
}

#[derive(Debug, Clone)]
struct StoredFabricProof {
    observer_node_id: String,
    observer_port_id: String,
    peer_node_id: String,
    peer_port_id: Option<String>,
    verified_at: String,
    expires_at: String,
    source: String,
}

struct TrustedImportMember {
    member: ExternalImportMember,
    authority_fingerprint: Option<String>,
}

fn trusted_import_member(
    conn: &Connection,
    node_id: &str,
) -> Result<TrustedImportMember, ClusterError> {
    conn.query_row(
        "SELECT name, source, authority_fingerprint FROM peer_facts WHERE node_id = ?1",
        [node_id],
        |row| {
            Ok(TrustedImportMember {
                member: ExternalImportMember {
                    node_id: node_id.to_owned(),
                    name: Some(row.get(0)?),
                    identity_authenticated: true,
                    identity_source: Some(row.get(1)?),
                },
                authority_fingerprint: Some(row.get(2)?),
            })
        },
    )
    .optional()
    .map(|member| {
        member.unwrap_or_else(|| TrustedImportMember {
            member: ExternalImportMember {
                node_id: node_id.to_owned(),
                name: None,
                identity_authenticated: false,
                identity_source: None,
            },
            authority_fingerprint: None,
        })
    })
    .map_err(Into::into)
}

fn active_fabric_proofs(
    conn: &Connection,
    selected: &HashSet<&str>,
    now: time::OffsetDateTime,
) -> Result<Vec<StoredFabricProof>, ClusterError> {
    let mut statement = conn.prepare(
        "SELECT observer_node_id, observer_port_id, peer_node_id, peer_port_id,
                verified_at, expires_at, source
         FROM fabric_peer_proofs
         ORDER BY observer_node_id, peer_node_id, observer_port_id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(StoredFabricProof {
            observer_node_id: row.get(0)?,
            observer_port_id: row.get(1)?,
            peer_node_id: row.get(2)?,
            peer_port_id: row.get(3)?,
            verified_at: row.get(4)?,
            expires_at: row.get(5)?,
            source: row.get(6)?,
        })
    })?;
    Ok(rows
        .filter_map(Result::ok)
        .filter(|proof| {
            selected.contains(proof.observer_node_id.as_str())
                && selected.contains(proof.peer_node_id.as_str())
                && time::OffsetDateTime::parse(
                    &proof.expires_at,
                    &time::format_description::well_known::Rfc3339,
                )
                .is_ok_and(|expires_at| expires_at > now)
                && proof.source == FabricProofSource::MutualTlsChallenge.as_str()
        })
        .collect())
}

fn reciprocal_links(proofs: &[StoredFabricProof]) -> Vec<AuthenticatedFabricLink> {
    let mut directed: HashMap<(&str, &str), Vec<&StoredFabricProof>> = HashMap::new();
    for proof in proofs {
        directed
            .entry((&proof.observer_node_id, &proof.peer_node_id))
            .or_default()
            .push(proof);
    }

    let mut links = Vec::new();
    let mut seen = HashSet::new();
    for proof in proofs {
        let (member_a, member_b) = if proof.observer_node_id < proof.peer_node_id {
            (&proof.observer_node_id, &proof.peer_node_id)
        } else {
            (&proof.peer_node_id, &proof.observer_node_id)
        };
        if !seen.insert((member_a.as_str(), member_b.as_str())) {
            continue;
        }
        let Some(forward) = directed.get(&(member_a.as_str(), member_b.as_str())) else {
            continue;
        };
        let Some(reverse) = directed.get(&(member_b.as_str(), member_a.as_str())) else {
            continue;
        };
        let Some((a, b)) = forward.iter().find_map(|a| {
            reverse
                .iter()
                .find(|b| {
                    a.peer_port_id
                        .as_ref()
                        .is_none_or(|port| port == &b.observer_port_id)
                        && b.peer_port_id
                            .as_ref()
                            .is_none_or(|port| port == &a.observer_port_id)
                })
                .map(|b| (*a, *b))
        }) else {
            continue;
        };
        links.push(AuthenticatedFabricLink {
            member_a_node_id: member_a.clone(),
            member_a_port_id: a.observer_port_id.clone(),
            member_b_node_id: member_b.clone(),
            member_b_port_id: b.observer_port_id.clone(),
            proof_source: FabricProofSource::MutualTlsChallenge.as_str().into(),
            path_topology: "unknown".into(),
            direct_connection_proven: false,
            verified_at: std::cmp::max(a.verified_at.clone(), b.verified_at.clone()),
            expires_at: std::cmp::min(a.expires_at.clone(), b.expires_at.clone()),
        });
    }
    links
}

/// Return only current reciprocal proofs as authenticated fabric links.
pub fn authenticated_fabric_links_for_node(
    conn: &Connection,
    node_id: &str,
    now: &str,
) -> Result<Vec<AuthenticatedFabricLink>, ClusterError> {
    let now = time::OffsetDateTime::parse(now, &time::format_description::well_known::Rfc3339)
        .map_err(|_| ClusterError::InvalidFabricProof("observation time is not RFC3339".into()))?;
    let mut statement = conn.prepare(
        "SELECT observer_node_id, observer_port_id, peer_node_id, peer_port_id,
                verified_at, expires_at, source
         FROM fabric_peer_proofs
         WHERE observer_node_id = ?1 OR peer_node_id = ?1
         ORDER BY observer_node_id, peer_node_id, observer_port_id",
    )?;
    let proofs = statement
        .query_map([node_id], |row| {
            Ok(StoredFabricProof {
                observer_node_id: row.get(0)?,
                observer_port_id: row.get(1)?,
                peer_node_id: row.get(2)?,
                peer_port_id: row.get(3)?,
                verified_at: row.get(4)?,
                expires_at: row.get(5)?,
                source: row.get(6)?,
            })
        })?
        .filter_map(Result::ok)
        .filter(|proof| {
            time::OffsetDateTime::parse(
                &proof.expires_at,
                &time::format_description::well_known::Rfc3339,
            )
            .is_ok_and(|expires_at| expires_at > now)
                && proof.source == FabricProofSource::MutualTlsChallenge.as_str()
        })
        .collect::<Vec<_>>();
    Ok(reciprocal_links(&proofs)
        .into_iter()
        .filter(|link| link.member_a_node_id == node_id || link.member_b_node_id == node_id)
        .collect())
}

fn connected_members(
    member_node_ids: &[String],
    links: &[AuthenticatedFabricLink],
) -> HashSet<String> {
    let Some(first) = member_node_ids.first() else {
        return HashSet::new();
    };
    let mut connected = HashSet::from([first.clone()]);
    loop {
        let before = connected.len();
        for link in links {
            if connected.contains(&link.member_a_node_id) {
                connected.insert(link.member_b_node_id.clone());
            }
            if connected.contains(&link.member_b_node_id) {
                connected.insert(link.member_a_node_id.clone());
            }
        }
        if connected.len() == before {
            return connected;
        }
    }
}

/// Build external-cluster candidates from trusted identity and fabric evidence without writes.
pub fn preview_external_import(
    conn: &Connection,
    name: &str,
    member_node_ids: &[String],
    now: &str,
) -> Result<ExternalClusterImportPreview, ClusterError> {
    let existing_cluster: i64 = conn.query_row(
        "SELECT COUNT(*) FROM cluster_state WHERE singleton = 1",
        [],
        |row| row.get(0),
    )?;
    if existing_cluster > 0 {
        return Err(ClusterError::AlreadyClustered);
    }
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 120 {
        return Err(ClusterError::InvalidName);
    }
    if member_node_ids.len() < 2 {
        return Err(ClusterError::MembershipTooSmall);
    }
    if member_node_ids.len() > 64 {
        return Err(ClusterError::MembershipTooLarge);
    }
    let selected: HashSet<&str> = member_node_ids.iter().map(String::as_str).collect();
    if selected.len() != member_node_ids.len() {
        return Err(ClusterError::DuplicateMember);
    }
    if member_node_ids
        .iter()
        .any(|node_id| uuid::Uuid::parse_str(node_id).is_err())
    {
        return Err(ClusterError::InvalidFabricProof(
            "member node IDs must be UUIDs".into(),
        ));
    }
    let now = time::OffsetDateTime::parse(now, &time::format_description::well_known::Rfc3339)
        .map_err(|_| ClusterError::InvalidFabricProof("preview time is not RFC3339".into()))?;

    let trusted_members = member_node_ids
        .iter()
        .map(|node_id| trusted_import_member(conn, node_id))
        .collect::<Result<Vec<_>, _>>()?;
    let members = trusted_members
        .iter()
        .map(|trusted| trusted.member.clone())
        .collect::<Vec<_>>();
    let proofs = active_fabric_proofs(conn, &selected, now)?;
    let authenticated_links = reciprocal_links(&proofs);
    let connected = connected_members(member_node_ids, &authenticated_links);
    let mut blockers = Vec::new();
    for member in &members {
        if !member.identity_authenticated {
            blockers.push(ExternalImportBlocker {
                code: "MEMBER_IDENTITY_UNVERIFIED".into(),
                member_node_id: Some(member.node_id.clone()),
            });
        }
    }
    if let Some(authority) = trusted_members
        .iter()
        .find_map(|member| member.authority_fingerprint.as_deref())
    {
        for member in &trusted_members {
            if member
                .authority_fingerprint
                .as_deref()
                .is_some_and(|candidate| candidate != authority)
            {
                blockers.push(ExternalImportBlocker {
                    code: "MEMBER_AUTHORITY_MISMATCH".into(),
                    member_node_id: Some(member.member.node_id.clone()),
                });
            }
        }
    }
    for node_id in member_node_ids {
        if !connected.contains(node_id) {
            blockers.push(ExternalImportBlocker {
                code: "FABRIC_PEER_NOT_RECIPROCAL".into(),
                member_node_id: Some(node_id.clone()),
            });
        }
    }
    let evidence_complete = blockers.is_empty();

    Ok(ExternalClusterImportPreview {
        name: name.into(),
        configuration_owner: EXTERNALLY_CONFIGURED.into(),
        members,
        authenticated_links,
        evidence_complete,
        registration_available: false,
        automatic_topology_available: false,
        takeover_available: false,
        blockers,
        preservation_guarantees: [
            "netplan",
            "ssh",
            "ray",
            "vllm",
            "models",
            "containers",
            "services",
        ]
        .map(str::to_owned)
        .into(),
    })
}

#[cfg(test)]
#[path = "cluster_import/external_import_tests.rs"]
mod external_import_tests;

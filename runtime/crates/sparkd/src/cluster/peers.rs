use super::*;

/// Advertised member facts used for compatibility checks.
#[derive(Debug, Clone, PartialEq)]
pub struct MemberFacts {
    pub node_id: String,
    pub name: String,
    pub authority_fingerprint: String,
    pub runtime_version: String,
    pub engine_image: String,
}

/// Use peer facts established through authenticated peer evidence, never caller assertions or copied local identity.
#[derive(Debug, Clone, PartialEq)]
pub struct PeerFacts {
    pub node_id: String,
    pub name: String,
    pub authority_fingerprint: String,
    pub runtime_version: String,
    pub engine_image: String,
}

impl From<PeerFacts> for MemberFacts {
    fn from(facts: PeerFacts) -> Self {
        MemberFacts {
            node_id: facts.node_id,
            name: facts.name,
            authority_fingerprint: facts.authority_fingerprint,
            runtime_version: facts.runtime_version,
            engine_image: facts.engine_image,
        }
    }
}

/// Require shared authority.
pub fn check_authority(facts: &[MemberFacts]) -> Result<(), ClusterError> {
    let mut fingerprints = facts.iter().map(|f| f.authority_fingerprint.as_str());
    let first = fingerprints.next().unwrap_or_default().to_owned();
    if fingerprints.any(|fingerprint| fingerprint != first) {
        return Err(ClusterError::AuthorityMismatch);
    }
    Ok(())
}

/// Check runtime and engine-image compatibility across members.
pub fn check_compatibility(facts: &[MemberFacts]) -> Result<(), ClusterError> {
    let mut runtimes = facts.iter().map(|f| f.runtime_version.as_str());
    let runtime = runtimes.next().unwrap_or_default().to_owned();
    if runtimes.any(|other| other != runtime) {
        return Err(ClusterError::VersionMismatch(
            "runtime versions differ across members".into(),
        ));
    }
    let mut images = facts.iter().map(|f| f.engine_image.as_str());
    let image = images.next().unwrap_or_default().to_owned();
    if images.any(|other| other != image) {
        return Err(ClusterError::VersionMismatch(
            "engine images differ across members".into(),
        ));
    }
    Ok(())
}

/// Record facts only after pinned mutual TLS or signed invitation verification; no HTTP route writes this registry.
pub fn record_peer_facts(
    conn: &Connection,
    facts: &PeerFacts,
    source: &str,
) -> Result<(), ClusterError> {
    conn.execute(
        "INSERT INTO peer_facts
            (node_id, name, authority_fingerprint, runtime_version,
             engine_image, recorded_at, source)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(node_id) DO UPDATE SET
            name = excluded.name,
            authority_fingerprint = excluded.authority_fingerprint,
            runtime_version = excluded.runtime_version,
            engine_image = excluded.engine_image,
            recorded_at = excluded.recorded_at,
            source = excluded.source",
        rusqlite::params![
            facts.node_id,
            facts.name,
            facts.authority_fingerprint,
            facts.runtime_version,
            facts.engine_image,
            crate::store::now_iso8601(),
            source
        ],
    )?;
    Ok(())
}

/// Read one peer's recorded facts, if any.
pub fn peer_facts(conn: &Connection, node_id: &str) -> Result<Option<PeerFacts>, ClusterError> {
    let row = conn
        .query_row(
            "SELECT node_id, name, authority_fingerprint, runtime_version, engine_image
             FROM peer_facts WHERE node_id = ?1",
            [node_id],
            |row| {
                Ok(PeerFacts {
                    node_id: row.get(0)?,
                    name: row.get(1)?,
                    authority_fingerprint: row.get(2)?,
                    runtime_version: row.get(3)?,
                    engine_image: row.get(4)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Resolve ordered member facts from trusted storage and reject the first unknown peer without fallback evidence.
pub fn resolve_cluster_member_facts(
    conn: &Connection,
    member_node_ids: &[String],
) -> Result<Vec<PeerFacts>, ClusterError> {
    member_node_ids
        .iter()
        .map(|node_id| {
            peer_facts(conn, node_id)?.ok_or_else(|| ClusterError::UnknownPeer(node_id.clone()))
        })
        .collect()
}

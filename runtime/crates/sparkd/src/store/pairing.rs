use super::{
    Connection, DeviceListRow, INSTALLER_DEVICE_NAME, OptionalExtension, StoreError, insert_device,
    now, params, prune_expired_records,
};

/// Bind invitation input to its issuing device, including the install-time bootstrap issuer.
pub struct InvitationDraft<'a> {
    pub id: &'a uuid::Uuid,
    pub role: &'a str,
    pub nonce_hash: &'a [u8],
    pub issued_by: &'a uuid::Uuid,
    pub device_name_hint: Option<&'a str>,
    pub expires_at: &'a str,
    pub signed_payload_json: &'a str,
    pub join_code_hash: &'a [u8],
}

pub fn insert_invitation(conn: &Connection, draft: &InvitationDraft) -> Result<(), StoreError> {
    conn.execute(
        "INSERT INTO pairing_invitations
            (id, role, nonce_hash, issued_by_device_id, device_name_hint,
             issued_at, expires_at, consumed_at, consumed_by_device_id,
             revoked_at, signed_payload_json, join_code_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL, NULL, NULL, ?8, ?9)",
        params![
            draft.id.to_string(),
            draft.role,
            draft.nonce_hash,
            draft.issued_by.to_string(),
            draft.device_name_hint,
            now(),
            draft.expires_at,
            draft.signed_payload_json,
            draft.join_code_hash,
        ],
    )?;
    Ok(())
}

pub fn active_join_code_exists(conn: &Connection, hash: &[u8]) -> Result<bool, StoreError> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pairing_invitations
          WHERE join_code_hash = ?1
            AND consumed_at IS NULL
            AND revoked_at IS NULL
            AND expires_at > ?2",
        params![hash, now()],
        |row| row.get(0),
    )?;
    Ok(count > 0)
}

pub fn load_pending_invitation_by_join_code(
    conn: &Connection,
    hash: &[u8],
) -> Result<Option<InvitationRow>, StoreError> {
    let row = conn
        .query_row(
            "SELECT id, role, expires_at, signed_payload_json
               FROM pairing_invitations
              WHERE join_code_hash = ?1
                AND consumed_at IS NULL
                AND revoked_at IS NULL
                AND expires_at > ?2",
            params![hash, now()],
            |row| {
                Ok(InvitationRow {
                    id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?,
                    role: row.get(1)?,
                    expires_at: row.get(2)?,
                    signed_payload_json: row.get(3)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Create the typed revocable installer issuer required by the non-null invitation provenance constraint.
pub fn insert_installer_device(
    conn: &Connection,
    id: &uuid::Uuid,
    public_key_spki: &[u8],
) -> Result<(), StoreError> {
    insert_device(
        conn,
        id,
        INSTALLER_DEVICE_NAME,
        "macos",
        public_key_spki,
        &crate::crypto::sha256_hex(public_key_spki),
        "administrator",
    )
}

/// Load a pending (unconsumed, unrevoked) invitation by id.
#[derive(Debug, Clone)]
pub struct InvitationRow {
    pub id: uuid::Uuid,
    pub role: String,
    pub expires_at: String,
    pub signed_payload_json: String,
}

/// Load consumed or revoked invitations too so callers can distinguish unknown from unavailable.
pub fn load_invitation(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<InvitationRow>, StoreError> {
    let row = conn
        .query_row(
            "SELECT id, role, expires_at, signed_payload_json
               FROM pairing_invitations WHERE id = ?1",
            params![id.to_string()],
            |r| {
                Ok(InvitationRow {
                    id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    role: r.get(1)?,
                    expires_at: r.get(2)?,
                    signed_payload_json: r.get(3)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

pub fn load_pending_invitation(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<InvitationRow>, StoreError> {
    let row = conn
        .query_row(
            "SELECT id, role, expires_at, signed_payload_json
               FROM pairing_invitations
              WHERE id = ?1 AND consumed_at IS NULL AND revoked_at IS NULL",
            params![id.to_string()],
            |r| {
                Ok(InvitationRow {
                    id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    role: r.get(1)?,
                    expires_at: r.get(2)?,
                    signed_payload_json: r.get(3)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Recover consumed invitations only for the exact active grant after matching every identity field; never make them reusable.
#[derive(Debug, Clone)]
pub struct ConsumedInvitationGrant {
    pub invitation: InvitationRow,
    pub device: DeviceListRow,
    pub public_key_fingerprint: String,
    pub presence_key_fingerprint: Option<String>,
}

pub fn consumed_invitation_grant(
    conn: &Connection,
    invitation_id: &uuid::Uuid,
) -> Result<Option<ConsumedInvitationGrant>, StoreError> {
    conn.query_row(
        "SELECT i.id, i.role, i.expires_at, i.signed_payload_json,
                d.id, d.display_name, d.platform, d.role, d.paired_at,
                d.last_seen_at, d.public_key_fingerprint,
                d.presence_public_key_fingerprint
           FROM pairing_invitations i
           JOIN devices d ON d.id = i.consumed_by_device_id
          WHERE i.id = ?1
            AND i.consumed_at IS NOT NULL
            AND i.revoked_at IS NULL
            AND d.revoked_at IS NULL",
        params![invitation_id.to_string()],
        |row| {
            Ok(ConsumedInvitationGrant {
                invitation: InvitationRow {
                    id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?,
                    role: row.get(1)?,
                    expires_at: row.get(2)?,
                    signed_payload_json: row.get(3)?,
                },
                device: DeviceListRow {
                    id: uuid::Uuid::parse_str(&row.get::<_, String>(4)?).map_err(|error| {
                        rusqlite::Error::FromSqlConversionFailure(
                            4,
                            rusqlite::types::Type::Text,
                            Box::new(error),
                        )
                    })?,
                    display_name: row.get(5)?,
                    platform: row.get(6)?,
                    role: row.get(7)?,
                    paired_at: row.get(8)?,
                    last_seen_at: row.get(9)?,
                    revoked: false,
                },
                public_key_fingerprint: row.get(10)?,
                presence_key_fingerprint: row.get(11)?,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

/// Atomically mark an invitation consumed by the claiming device.
pub fn consume_invitation(
    conn: &Connection,
    id: &uuid::Uuid,
    consumed_by: &uuid::Uuid,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE pairing_invitations
            SET consumed_at = ?1, consumed_by_device_id = ?2
          WHERE id = ?3 AND consumed_at IS NULL AND revoked_at IS NULL",
        params![now(), consumed_by.to_string(), id.to_string()],
    )?;
    if changed == 0 {
        return Err(StoreError::InvitationUnavailable);
    }
    Ok(())
}

/// Retire only the invitation's exact installer issuer after checking its bootstrap name and role.
pub fn revoke_installer_grant_for(
    conn: &Connection,
    invitation_id: &uuid::Uuid,
) -> Result<usize, StoreError> {
    conn.execute(
        "UPDATE devices
            SET revoked_at = ?1
          WHERE id = (
                SELECT issued_by_device_id
                  FROM pairing_invitations
                 WHERE id = ?2
            )
            AND display_name = ?3
            AND role = 'administrator'
            AND revoked_at IS NULL",
        params![now(), invitation_id.to_string(), INSTALLER_DEVICE_NAME],
    )
    .map_err(Into::into)
}

/// Insert a pairing challenge bound to an invitation and a public key.
pub fn insert_challenge(
    conn: &Connection,
    id: &uuid::Uuid,
    invitation_id: &uuid::Uuid,
    challenge: &[u8; 32],
    device_public_key_fingerprint: &str,
    expires_at: &str,
) -> Result<(), StoreError> {
    prune_expired_records(conn, &now())?;
    conn.execute(
        "INSERT INTO pairing_challenges
            (id, invitation_id, challenge_hash, device_public_key_fingerprint,
             issued_at, expires_at, consumed_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)",
        params![
            id.to_string(),
            invitation_id.to_string(),
            challenge.to_vec(),
            device_public_key_fingerprint,
            now(),
            expires_at,
        ],
    )?;
    Ok(())
}

/// Load an unconsumed, unexpired challenge.
pub fn load_challenge(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<ChallengeRow>, StoreError> {
    let row = conn
        .query_row(
            "SELECT id, invitation_id, challenge_hash, expires_at,
                    device_public_key_fingerprint
               FROM pairing_challenges
              WHERE id = ?1 AND consumed_at IS NULL",
            params![id.to_string()],
            |r| {
                Ok(ChallengeRow {
                    id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    invitation_id: uuid::Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            1,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    challenge: r.get(2)?,
                    expires_at: r.get(3)?,
                    device_public_key_fingerprint: r.get(4)?,
                })
            },
        )
        .optional()?;
    Ok(row)
}

/// Consume a challenge atomically (single-claim).
pub fn consume_challenge(conn: &Connection, id: &uuid::Uuid) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE pairing_challenges SET consumed_at = ?1 WHERE id = ?2 AND consumed_at IS NULL",
        params![now(), id.to_string()],
    )?;
    if changed == 0 {
        return Err(StoreError::NotFound("challenge"));
    }
    Ok(())
}

/// Has this node already finished first-owner pairing?
pub fn has_owner(conn: &Connection) -> Result<bool, StoreError> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM devices WHERE role = 'owner' AND revoked_at IS NULL",
        [],
        |r| r.get(0),
    )?;
    Ok(count > 0)
}

#[derive(Debug, Clone)]
pub struct ChallengeRow {
    pub id: uuid::Uuid,
    pub invitation_id: uuid::Uuid,
    pub challenge: Vec<u8>,
    pub expires_at: String,
    /// Bind the challenge to SHA-256 of the issued-for SPKI so observers cannot claim it with another key.
    pub device_public_key_fingerprint: String,
}

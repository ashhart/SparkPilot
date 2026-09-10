use super::{Connection, OptionalExtension, StoreError, now, params};

/// Insert a device grant.
pub fn insert_device(
    conn: &Connection,
    id: &uuid::Uuid,
    display_name: &str,
    platform: &str,
    public_key_spki: &[u8],
    public_key_fingerprint: &str,
    role: &str,
) -> Result<(), StoreError> {
    insert_device_with_presence_key(
        conn,
        id,
        display_name,
        platform,
        public_key_spki,
        public_key_fingerprint,
        role,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn insert_device_with_presence_key(
    conn: &Connection,
    id: &uuid::Uuid,
    display_name: &str,
    platform: &str,
    public_key_spki: &[u8],
    public_key_fingerprint: &str,
    role: &str,
    presence_key: Option<(&[u8], &str)>,
) -> Result<(), StoreError> {
    let (presence_public_key_spki, presence_public_key_fingerprint) = presence_key
        .map(|(spki, fingerprint)| (Some(spki), Some(fingerprint)))
        .unwrap_or((None, None));
    conn.execute(
        "INSERT INTO devices
            (id, display_name, platform, public_key_spki, public_key_fingerprint,
             presence_public_key_spki, presence_public_key_fingerprint,
             role, paired_at, last_seen_at, revoked_at, metadata_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL, NULL, '{}')",
        params![
            id.to_string(),
            display_name,
            platform,
            public_key_spki,
            public_key_fingerprint,
            presence_public_key_spki,
            presence_public_key_fingerprint,
            role,
            now(),
        ],
    )?;
    Ok(())
}

pub fn load_presence_key_by_device_id(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<Vec<u8>>, StoreError> {
    conn.query_row(
        "SELECT presence_public_key_spki FROM devices
          WHERE id = ?1 AND revoked_at IS NULL
            AND presence_public_key_spki IS NOT NULL",
        params![id.to_string()],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceKeyEnrollment {
    Enrolled,
    AlreadyEnrolled,
    Conflict,
}

/// Enroll presence keys once; identical canonical retries succeed, while replacing an existing key requires recovery.
pub fn enroll_presence_key(
    conn: &Connection,
    device_id: &uuid::Uuid,
    canonical_spki: &[u8],
    fingerprint: &str,
) -> Result<PresenceKeyEnrollment, StoreError> {
    let existing: Option<Option<String>> = conn
        .query_row(
            "SELECT presence_public_key_fingerprint FROM devices
              WHERE id = ?1 AND revoked_at IS NULL",
            params![device_id.to_string()],
            |row| row.get(0),
        )
        .optional()?;
    match existing {
        None => Err(StoreError::NotFound("device")),
        Some(Some(existing)) if existing == fingerprint => {
            Ok(PresenceKeyEnrollment::AlreadyEnrolled)
        }
        Some(Some(_)) => Ok(PresenceKeyEnrollment::Conflict),
        Some(None) => {
            let changed = conn.execute(
                "UPDATE devices
                    SET presence_public_key_spki = ?1,
                        presence_public_key_fingerprint = ?2
                  WHERE id = ?3
                    AND revoked_at IS NULL
                    AND presence_public_key_spki IS NULL
                    AND presence_public_key_fingerprint IS NULL",
                params![canonical_spki, fingerprint, device_id.to_string()],
            )?;
            if changed == 1 {
                Ok(PresenceKeyEnrollment::Enrolled)
            } else {
                let stored: Option<String> = conn.query_row(
                    "SELECT presence_public_key_fingerprint FROM devices WHERE id = ?1",
                    params![device_id.to_string()],
                    |row| row.get(0),
                )?;
                if stored.as_deref() == Some(fingerprint) {
                    Ok(PresenceKeyEnrollment::AlreadyEnrolled)
                } else {
                    Ok(PresenceKeyEnrollment::Conflict)
                }
            }
        }
    }
}

/// Load a non-revoked device by public key fingerprint.
#[derive(Debug, Clone)]
pub struct DeviceRow {
    pub id: uuid::Uuid,
    pub display_name: String,
    pub role: String,
    pub public_key_spki: Vec<u8>,
}

pub fn load_device_by_fingerprint(
    conn: &Connection,
    public_key_fingerprint: &str,
) -> Result<Option<DeviceRow>, StoreError> {
    conn.query_row(
        "SELECT id, display_name, role, public_key_spki FROM devices
          WHERE public_key_fingerprint = ?1 AND revoked_at IS NULL",
        params![public_key_fingerprint],
        |r| {
            Ok(DeviceRow {
                id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                display_name: r.get(1)?,
                role: r.get(2)?,
                public_key_spki: r.get(3)?,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

/// Load a non-revoked device by id (used by the authorisation middleware).
pub fn load_device_by_id(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<DeviceRow>, StoreError> {
    conn.query_row(
        "SELECT id, display_name, role, public_key_spki FROM devices
          WHERE id = ?1 AND revoked_at IS NULL",
        params![id.to_string()],
        |r| {
            Ok(DeviceRow {
                id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                display_name: r.get(1)?,
                role: r.get(2)?,
                public_key_spki: r.get(3)?,
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NonceAdmission {
    Admitted,
    Replayed,
}

/// Serialize nonce admission in an immediate transaction, handling only replay-key conflicts while preserving other storage errors.
pub fn admit_request_nonce(
    conn: &mut Connection,
    device_id: &uuid::Uuid,
    nonce_hash: &[u8],
    admitted_at: &str,
    expires_at: &str,
) -> Result<NonceAdmission, StoreError> {
    let transaction = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    transaction.execute(
        "DELETE FROM request_nonces WHERE expires_at <= ?1",
        params![admitted_at],
    )?;
    let changed = transaction.execute(
        "INSERT INTO request_nonces (device_id, nonce_hash, seen_at, expires_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(device_id, nonce_hash) DO NOTHING",
        params![device_id.to_string(), nonce_hash, admitted_at, expires_at],
    )?;
    let result = if changed == 1 {
        // Update activity with verified fresh-nonce admission using server time, coalesced per minute; failures and replays cannot refresh it.
        transaction.execute(
            "UPDATE devices SET last_seen_at = ?1
             WHERE id = ?2 AND revoked_at IS NULL
               AND (last_seen_at IS NULL
                    OR julianday(last_seen_at) IS NULL
                    OR julianday(last_seen_at) <= julianday(?1, '-60 seconds')
                    OR julianday(last_seen_at) > julianday(?1))",
            params![admitted_at, device_id.to_string()],
        )?;
        NonceAdmission::Admitted
    } else {
        NonceAdmission::Replayed
    };
    transaction.commit()?;
    Ok(result)
}

/// Resolve revoked devices' original roles too, so revocation authority and already-revoked responses remain correct.
pub fn device_role(conn: &Connection, id: &uuid::Uuid) -> Result<Option<String>, StoreError> {
    conn.query_row(
        "SELECT role FROM devices WHERE id = ?1",
        params![id.to_string()],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

/// Delete a device grant (revocation).
pub fn revoke_device(conn: &Connection, id: &uuid::Uuid) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE devices SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL",
        params![now(), id.to_string()],
    )?;
    if changed == 0 {
        return Err(StoreError::NotFound("device"));
    }
    Ok(())
}

pub fn device_row(conn: &Connection, id: &uuid::Uuid) -> Result<Option<DeviceListRow>, StoreError> {
    conn.query_row(
        "SELECT id, display_name, platform, role, paired_at, last_seen_at, revoked_at
           FROM devices WHERE id = ?1",
        params![id.to_string()],
        |row| {
            Ok(DeviceListRow {
                id: uuid::Uuid::parse_str(&row.get::<_, String>(0)?).map_err(|error| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(error),
                    )
                })?,
                display_name: row.get(1)?,
                platform: row.get(2)?,
                role: row.get(3)?,
                paired_at: row.get(4)?,
                last_seen_at: row.get(5)?,
                revoked: row.get::<_, Option<String>>(6)?.is_some(),
            })
        },
    )
    .optional()
    .map_err(Into::into)
}

pub fn update_device(
    conn: &Connection,
    id: &uuid::Uuid,
    display_name: Option<&str>,
    role: Option<&str>,
) -> Result<(), StoreError> {
    let changed = conn.execute(
        "UPDATE devices
            SET display_name = COALESCE(?2, display_name),
                role = COALESCE(?3, role)
          WHERE id = ?1 AND revoked_at IS NULL",
        params![id.to_string(), display_name, role],
    )?;
    if changed == 0 {
        return Err(StoreError::NotFound("device"));
    }
    Ok(())
}

pub fn load_active_device_role(
    conn: &Connection,
    id: &uuid::Uuid,
) -> Result<Option<String>, StoreError> {
    conn.query_row(
        "SELECT role FROM devices WHERE id = ?1 AND revoked_at IS NULL",
        params![id.to_string()],
        |row| row.get(0),
    )
    .optional()
    .map_err(Into::into)
}

pub fn active_owner_count(conn: &Connection) -> Result<i64, StoreError> {
    conn.query_row(
        "SELECT COUNT(*) FROM devices WHERE role = 'owner' AND revoked_at IS NULL",
        [],
        |row| row.get(0),
    )
    .map_err(Into::into)
}

/// List all devices (used by the administrator device list).
pub fn list_devices(conn: &Connection) -> Result<Vec<DeviceListRow>, StoreError> {
    let mut stmt = conn.prepare(
        "SELECT id, display_name, platform, role, paired_at, last_seen_at,
                revoked_at IS NOT NULL AS revoked
           FROM devices ORDER BY paired_at",
    )?;
    let rows = stmt
        .query_map([], |r| {
            Ok(DeviceListRow {
                id: uuid::Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                    rusqlite::Error::FromSqlConversionFailure(
                        0,
                        rusqlite::types::Type::Text,
                        Box::new(e),
                    )
                })?,
                display_name: r.get(1)?,
                platform: r.get(2)?,
                role: r.get(3)?,
                paired_at: r.get(4)?,
                last_seen_at: r.get(5)?,
                revoked: r.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct DeviceListRow {
    pub id: uuid::Uuid,
    pub display_name: String,
    pub platform: String,
    pub role: String,
    pub paired_at: String,
    pub last_seen_at: Option<String>,
    pub revoked: bool,
}

/// Return device project memberships for event visibility filtering.
pub fn project_ids_for_device(
    conn: &Connection,
    device_id: &uuid::Uuid,
) -> Result<std::collections::HashSet<uuid::Uuid>, StoreError> {
    let mut statement =
        conn.prepare("SELECT project_id FROM project_members WHERE device_id = ?1")?;
    let rows = statement.query_map(rusqlite::params![device_id.to_string()], |row| {
        row.get::<_, String>(0)
    })?;
    let mut projects = std::collections::HashSet::new();
    for row in rows {
        if let Ok(id) = uuid::Uuid::parse_str(&row?) {
            projects.insert(id);
        }
    }
    Ok(projects)
}

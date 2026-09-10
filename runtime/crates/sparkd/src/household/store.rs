use super::*;

pub(super) fn notes(
    conn: &Connection,
    caller: Uuid,
    admin: bool,
) -> Result<Vec<Value>, StoreError> {
    let mut statement = conn.prepare("SELECT id,title,body,revision,author_device_id,author_name,updated_by_name,created_at,updated_at FROM household_notes WHERE deleted_at IS NULL ORDER BY updated_at DESC,id LIMIT 256")?;
    let rows = statement.query_map([], |row| {
        let author: String = row.get(4)?;
        Ok(json!({"id":row.get::<_,String>(0)?,"title":row.get::<_,String>(1)?,"body":row.get::<_,String>(2)?,
            "revision":row.get::<_,u64>(3)?,"author_name":row.get::<_,String>(5)?,"updated_by_name":row.get::<_,String>(6)?,
            "created_at":row.get::<_,String>(7)?,"updated_at":row.get::<_,String>(8)?,"can_edit":admin || author==caller.to_string()}))
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(super) fn members(conn: &Connection, now: i64, admin: bool) -> Result<Vec<Value>, StoreError> {
    let mut statement = conn.prepare("SELECT d.id, EXISTS(SELECT 1 FROM household_members h WHERE h.device_id=d.id) FROM devices d WHERE d.revoked_at IS NULL ORDER BY d.display_name,d.id LIMIT 256")?;
    let records = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut result = Vec::new();
    for (id, joined) in records {
        let Ok(id) = Uuid::parse_str(&id) else {
            continue;
        };
        if let Some(member) = eligible(conn, id, now)? {
            let joined = joined || member.administrator;
            if admin || joined {
                result.push(json!({"device_id":id,"name":member.name,"joined":joined,"administrator":member.administrator}));
            }
        } else if admin && joined {
            let name: String = conn.query_row(
                "SELECT display_name FROM devices WHERE id=?1",
                [id.to_string()],
                |row| row.get(0),
            )?;
            result.push(json!({"device_id":id,"name":name,"joined":true,"administrator":false}));
        }
    }
    Ok(result)
}

pub(super) fn set_member(
    conn: &Connection,
    principal: &Principal,
    request: &MemberRequest,
    now: i64,
    timestamp: &str,
) -> Result<StoredResponse, StoreError> {
    let target = eligible(conn, request.device_id, now)?;
    // Removal also works after guest access expires or is paused, so later reactivation cannot restore household access.
    if request.joined && target.is_none() {
        return Ok(stored_error(
            StatusCode::CONFLICT,
            "HOUSEHOLD_MEMBER_UNAVAILABLE",
            "Choose a paired device with active access.",
        ));
    }
    if target.as_ref().is_some_and(|member| member.administrator) {
        return Ok(stored_error(
            StatusCode::CONFLICT,
            "HOUSEHOLD_OWNER_REQUIRED",
            "Spark owners and administrators manage the household automatically.",
        ));
    }
    if request.joined {
        conn.execute("INSERT INTO household_members(device_id,added_by,added_at) VALUES(?1,?2,?3) ON CONFLICT(device_id) DO NOTHING", params![request.device_id.to_string(),principal.device_id.to_string(),timestamp])?;
    } else {
        conn.execute(
            "DELETE FROM household_members WHERE device_id=?1",
            [request.device_id.to_string()],
        )?;
    }
    Ok(StoredResponse {
        status: StatusCode::OK,
        body: json!({"id":request.device_id,"revision":0,"removed":!request.joined}),
        operation_id: None,
    })
}

pub(super) fn save_note(
    conn: &Connection,
    principal: &Principal,
    member: &Member,
    request: &NoteRequest,
    timestamp: &str,
) -> Result<StoredResponse, StoreError> {
    if request.expected_revision > i64::MAX as u64 - 1
        || (!request.delete
            && (request.title.trim().is_empty()
                || request.title.len() > 240
                || request.body.trim().is_empty()
                || request.body.len() > 16_384))
    {
        return Ok(stored_error(
            StatusCode::UNPROCESSABLE_ENTITY,
            "HOUSEHOLD_NOTE_INVALID",
            "Use a title of up to 240 bytes and a note of up to 16 KB.",
        ));
    }
    let existing: Option<(u64,String,bool)> = conn.query_row("SELECT revision,author_device_id,deleted_at IS NOT NULL FROM household_notes WHERE id=?1", [request.id.to_string()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional()?;
    match existing {
        Some((revision, author, deleted)) => {
            if author != principal.device_id.to_string() && !member.administrator {
                return Ok(stored_error(
                    StatusCode::FORBIDDEN,
                    "HOUSEHOLD_NOTE_READ_ONLY",
                    "Only the author or a Spark administrator can change this note.",
                ));
            }
            if deleted || revision != request.expected_revision {
                return Ok(stored_error(
                    StatusCode::CONFLICT,
                    "HOUSEHOLD_NOTE_CHANGED",
                    "This note changed on another device; reload it before saving.",
                ));
            }
            conn.execute("UPDATE household_notes SET title=?2,body=?3,revision=revision+1,updated_by_name=?4,updated_at=?5,deleted_at=?6 WHERE id=?1",params![request.id.to_string(),if request.delete {""} else {request.title.trim()},if request.delete {""} else {&request.body},member.name,timestamp,request.delete.then_some(timestamp)])?;
        }
        None => {
            if request.delete || request.expected_revision != 0 {
                return Ok(stored_error(
                    StatusCode::CONFLICT,
                    "HOUSEHOLD_NOTE_CHANGED",
                    "This note is no longer available; reload the household.",
                ));
            }
            let count: i64 = conn.query_row(
                "SELECT COUNT(*) FROM household_notes WHERE deleted_at IS NULL",
                [],
                |row| row.get(0),
            )?;
            if count >= MAX_NOTES {
                return Ok(stored_error(
                    StatusCode::CONFLICT,
                    "HOUSEHOLD_FULL",
                    "Remove an old household note before adding another.",
                ));
            }
            conn.execute("INSERT INTO household_notes(id,title,body,revision,author_device_id,author_name,updated_by_name,created_at,updated_at) VALUES(?1,?2,?3,1,?4,?5,?5,?6,?6)",params![request.id.to_string(),request.title.trim(),request.body,principal.device_id.to_string(),member.name,timestamp])?;
        }
    }
    Ok(StoredResponse {
        status: StatusCode::OK,
        body: json!({"id":request.id,"revision":request.expected_revision+1,"removed":request.delete}),
        operation_id: None,
    })
}

//! The durable rows: what the owner asked for, when it next runs, and what every run produced.

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use uuid::Uuid;

use super::schedule::Schedule;
use super::timezone::Timezone;
use crate::store::StoreError;

/// How many automations one Spark keeps, matching the contract's `max_automations`.
pub const MAX_AUTOMATIONS: i64 = 32;
/// How many runs of one automation are kept.
pub const MAX_RUNS_KEPT: i64 = 64;
/// A slot older than this is recorded as missed rather than fired late.
pub const MISSED_GRACE_SECONDS: i64 = 3_600;
/// A backlog is counted only this far; past it the aggregate says so rather than walking a year of slots.
pub const MAX_COUNTED_MISSES: u32 = 1_024;

/// One automation as the owner sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Automation {
    pub id: Uuid,
    pub owner_device_id: Uuid,
    pub name: String,
    pub instructions: String,
    pub schedule_preset: String,
    pub schedule_expression: String,
    pub timezone: String,
    pub model_id: String,
    pub profile_id: Option<String>,
    pub web_access: bool,
    pub notify: bool,
    pub enabled: bool,
    pub next_run_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}

/// One run of one automation, with the result and every tool call it made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutomationRun {
    pub id: Uuid,
    pub automation_id: Uuid,
    pub operation_id: Option<Uuid>,
    pub state: String,
    pub trigger: String,
    pub scheduled_for: Option<i64>,
    pub started_at: i64,
    pub finished_at: Option<i64>,
    pub result_text: Option<String>,
    pub error_code: Option<String>,
    pub tool_calls: Vec<Value>,
}

const COLUMNS: &str = "id,owner_device_id,name,instructions,schedule_preset,schedule_expression,timezone,model_id,profile_id,web_access,notify,enabled,next_run_at,created_at,updated_at";
const RUN_COLUMNS: &str = "id,automation_id,operation_id,state,trigger,scheduled_for,started_at,finished_at,result_text,error_code,tool_calls_json";

fn uuid(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Uuid> {
    Uuid::parse_str(&row.get::<_, String>(index)?).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Text,
            Box::new(error),
        )
    })
}

fn optional_uuid(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Option<Uuid>> {
    row.get::<_, Option<String>>(index)?
        .map(|raw| {
            Uuid::parse_str(&raw).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    index,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Automation> {
    Ok(Automation {
        id: uuid(row, 0)?,
        owner_device_id: uuid(row, 1)?,
        name: row.get(2)?,
        instructions: row.get(3)?,
        schedule_preset: row.get(4)?,
        schedule_expression: row.get(5)?,
        timezone: row.get(6)?,
        model_id: row.get(7)?,
        profile_id: row.get(8)?,
        web_access: row.get::<_, i64>(9)? == 1,
        notify: row.get::<_, i64>(10)? == 1,
        enabled: row.get::<_, i64>(11)? == 1,
        next_run_at: row.get(12)?,
        created_at: row.get(13)?,
        updated_at: row.get(14)?,
    })
}

fn run_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AutomationRun> {
    let raw: String = row.get(10)?;
    Ok(AutomationRun {
        id: uuid(row, 0)?,
        automation_id: uuid(row, 1)?,
        operation_id: optional_uuid(row, 2)?,
        state: row.get(3)?,
        trigger: row.get(4)?,
        scheduled_for: row.get(5)?,
        started_at: row.get(6)?,
        finished_at: row.get(7)?,
        result_text: row.get(8)?,
        error_code: row.get(9)?,
        tool_calls: serde_json::from_str(&raw).unwrap_or_default(),
    })
}

pub fn list(conn: &Connection) -> Result<Vec<Automation>, StoreError> {
    Ok(conn
        .prepare(&format!(
            "SELECT {COLUMNS} FROM automations ORDER BY created_at,id LIMIT {MAX_AUTOMATIONS}"
        ))?
        .query_map([], row)?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn get(conn: &Connection, id: Uuid) -> Result<Option<Automation>, StoreError> {
    Ok(conn
        .query_row(
            &format!("SELECT {COLUMNS} FROM automations WHERE id=?1"),
            [id.to_string()],
            row,
        )
        .optional()?)
}

pub fn count(conn: &Connection) -> Result<i64, StoreError> {
    Ok(conn.query_row("SELECT COUNT(*) FROM automations", [], |row| row.get(0))?)
}

/// The first slot strictly after `after`, read in the automation's own zone.
pub fn next_slot(
    expression: &str,
    zone_name: &str,
    after: i64,
) -> Result<Option<i64>, &'static str> {
    let schedule = Schedule::parse(expression).map_err(|error| error.code())?;
    let zone = Timezone::load(zone_name).map_err(|error| error.code())?;
    Ok(schedule.next_after(after, &zone))
}

/// How many slots between `from` and `now` this schedule had, counted only as far as the bound.
pub fn missed_slots(expression: &str, zone_name: &str, from: i64, now: i64) -> (u32, bool) {
    let (Ok(schedule), Ok(zone)) = (Schedule::parse(expression), Timezone::load(zone_name)) else {
        return (1, false);
    };
    let mut counted = 1;
    let mut cursor = from;
    while counted < MAX_COUNTED_MISSES {
        match schedule.next_after(cursor, &zone) {
            Some(next) if next <= now => {
                counted += 1;
                cursor = next;
            }
            _ => return (counted, false),
        }
    }
    (counted, true)
}

#[allow(clippy::too_many_arguments)]
pub fn insert(
    conn: &Connection,
    node_id: Uuid,
    owner: Uuid,
    draft: &Automation,
    next_run_at: Option<i64>,
    now: i64,
) -> Result<Automation, StoreError> {
    conn.execute(
        "INSERT INTO automations VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?15)",
        params![
            draft.id.to_string(),
            node_id.to_string(),
            owner.to_string(),
            draft.name,
            draft.instructions,
            draft.schedule_preset,
            draft.schedule_expression,
            draft.timezone,
            draft.model_id,
            draft.profile_id,
            i64::from(draft.web_access),
            i64::from(draft.notify),
            i64::from(draft.enabled),
            next_run_at,
            now,
        ],
    )?;
    Ok(get(conn, draft.id)?.expect("inserted automation"))
}

/// Write the whole row back; callers overlay only the fields the request supplied.
pub fn update(conn: &Connection, updated: &Automation, now: i64) -> Result<Automation, StoreError> {
    conn.execute(
        "UPDATE automations SET name=?2,instructions=?3,schedule_preset=?4,schedule_expression=?5,timezone=?6,
           model_id=?7,profile_id=?8,web_access=?9,notify=?10,enabled=?11,next_run_at=?12,updated_at=?13 WHERE id=?1",
        params![
            updated.id.to_string(),
            updated.name,
            updated.instructions,
            updated.schedule_preset,
            updated.schedule_expression,
            updated.timezone,
            updated.model_id,
            updated.profile_id,
            i64::from(updated.web_access),
            i64::from(updated.notify),
            i64::from(updated.enabled),
            updated.next_run_at,
            now,
        ],
    )?;
    Ok(get(conn, updated.id)?.expect("updated automation"))
}

pub fn delete(conn: &Connection, id: Uuid) -> Result<bool, StoreError> {
    Ok(conn.execute("DELETE FROM automations WHERE id=?1", [id.to_string()])? == 1)
}

pub fn runs(conn: &Connection, automation: Uuid) -> Result<Vec<AutomationRun>, StoreError> {
    Ok(conn
        .prepare(&format!(
            "SELECT {RUN_COLUMNS} FROM automation_runs WHERE automation_id=?1
             ORDER BY started_at DESC,id LIMIT {MAX_RUNS_KEPT}"
        ))?
        .query_map([automation.to_string()], run_row)?
        .collect::<rusqlite::Result<Vec<_>>>()?)
}

pub fn run(conn: &Connection, id: Uuid) -> Result<Option<AutomationRun>, StoreError> {
    Ok(conn
        .query_row(
            &format!("SELECT {RUN_COLUMNS} FROM automation_runs WHERE id=?1"),
            [id.to_string()],
            run_row,
        )
        .optional()?)
}

/// The run this automation already has in flight, if any.
pub fn in_flight(conn: &Connection, automation: Uuid) -> Result<Option<Uuid>, StoreError> {
    Ok(conn
        .query_row(
            "SELECT id FROM automation_runs WHERE automation_id=?1 AND state='running' LIMIT 1",
            [automation.to_string()],
            |row| uuid(row, 0),
        )
        .optional()?)
}

/// Claim one slot. The unique indexes refuse a second claim for the same slot and a second run in flight, whatever the timing.
pub fn claim_run(
    conn: &Connection,
    automation: Uuid,
    trigger: &str,
    scheduled_for: Option<i64>,
    now: i64,
) -> Result<Option<Uuid>, StoreError> {
    let id = Uuid::new_v4();
    let claimed = conn.execute(
        "INSERT OR IGNORE INTO automation_runs
           SELECT ?1,?2,NULL,'running',?3,?4,?5,NULL,NULL,NULL,'[]'
           WHERE NOT EXISTS(SELECT 1 FROM automation_runs WHERE automation_id=?2 AND state='running')",
        params![
            id.to_string(),
            automation.to_string(),
            trigger,
            scheduled_for,
            now
        ],
    )?;
    if claimed == 0 {
        return Ok(None);
    }
    prune_runs(conn, automation)?;
    Ok(Some(id))
}

/// Record a slot that did not run, so the owner can see it happened and why.
pub fn record_skipped(
    conn: &Connection,
    automation: Uuid,
    slot: i64,
    now: i64,
    error_code: &str,
) -> Result<(), StoreError> {
    let id = Uuid::new_v4();
    conn.execute(
        "INSERT OR IGNORE INTO automation_runs
           VALUES (?1,?2,NULL,'skipped','schedule',?3,?4,?4,NULL,?5,'[]')",
        params![
            id.to_string(),
            automation.to_string(),
            slot,
            now,
            error_code
        ],
    )?;
    prune_runs(conn, automation)?;
    Ok(())
}

pub fn attach_operation(conn: &Connection, run: Uuid, operation: Uuid) -> Result<(), StoreError> {
    conn.execute(
        "UPDATE automation_runs SET operation_id=?2 WHERE id=?1",
        params![run.to_string(), operation.to_string()],
    )?;
    Ok(())
}

/// Settle one run. A run already settled is left as it is.
pub fn finish_run(
    conn: &Connection,
    run: Uuid,
    state: &str,
    result_text: Option<&str>,
    error_code: Option<&str>,
    tool_calls: &[Value],
    now: i64,
) -> Result<(), StoreError> {
    let calls = serde_json::to_string(tool_calls).unwrap_or_else(|_| "[]".to_owned());
    conn.execute(
        "UPDATE automation_runs SET state=?2,finished_at=?3,result_text=?4,error_code=?5,tool_calls_json=?6
           WHERE id=?1 AND state='running'",
        params![run.to_string(), state, now, result_text, error_code, calls],
    )?;
    Ok(())
}

/// The state of the most recent run, for the list the app shows.
pub fn last_run(conn: &Connection, automation: Uuid) -> Result<Option<(i64, String)>, StoreError> {
    Ok(conn
        .query_row(
            "SELECT started_at,state FROM automation_runs WHERE automation_id=?1
             ORDER BY started_at DESC,id LIMIT 1",
            [automation.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?)
}

fn prune_runs(conn: &Connection, automation: Uuid) -> Result<(), StoreError> {
    conn.execute(
        "DELETE FROM automation_runs WHERE automation_id=?1 AND state<>'running' AND id NOT IN
           (SELECT id FROM automation_runs WHERE automation_id=?1 AND state<>'running'
            ORDER BY started_at DESC,id LIMIT ?2)",
        params![automation.to_string(), MAX_RUNS_KEPT],
    )?;
    Ok(())
}

#[cfg(test)]
#[path = "store/tests.rs"]
mod tests;

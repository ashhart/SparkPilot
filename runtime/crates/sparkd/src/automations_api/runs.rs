use super::*;

const RUNS_ROUTE: &str = "/api/v1/automations/runs";

fn run_json(run: &AutomationRun) -> Value {
    json!({
        "id": run.id,
        "automation_id": run.automation_id,
        "operation_id": run.operation_id,
        "state": run.state,
        "trigger": run.trigger,
        "scheduled_for": run.scheduled_for,
        "started_at": run.started_at,
        "finished_at": run.finished_at,
        "result_text": run.result_text,
        "error_code": run.error_code,
        "tool_calls": run.tool_calls,
    })
}

pub async fn list_automation_runs(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    AxumPath(id): AxumPath<Uuid>,
) -> Result<Json<Value>, Denial> {
    state
        .require(&principal, Capability::AutomationRead)
        .resource(RUNS_ROUTE)
        .check()?;
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let conn = database.lock();
    let items = store::runs(&conn, id)
        .map_err(|_| unavailable())?
        .iter()
        .map(run_json)
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "items": items,
        "observed_at": state.clock.now().unix_timestamp(),
    })))
}

/// Run one automation now, through the same worker and the same durable operation the scheduler uses.
pub async fn run_automation(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    AxumPath(id): AxumPath<Uuid>,
    idempotency: IdempotencyRequest,
) -> Result<(StatusCode, Json<Value>), Denial> {
    state
        .require(&principal, Capability::AutomationManage)
        .resource(RUNS_ROUTE)
        .details(json!({"automation_id": id, "trigger": "manual"}))
        .check()?;
    let database = state.database.as_ref().ok_or_else(unavailable)?;
    let now = state.clock.now().unix_timestamp();
    let mut claimed = None;
    let result = {
        let _dispatch = state.automations.dispatch.lock();
        let mut conn = database.lock();
        state.idempotency.execute(&mut conn,&idempotency,|transaction| {
            let error_response = |status,code,message| {
                let (_,Json(body)) = envelope(status,code,message);
                crate::idempotency::StoredResponse {status,body,operation_id:None}
            };
            let Some(automation) = store::get(transaction,id)? else {
                return Ok(error_response(StatusCode::NOT_FOUND,"AUTOMATION_NOT_FOUND","this Spark has no automation with that id"));
            };
            let Some(run_id) = store::claim_run(transaction,id,"manual",None,now)? else {
                return Ok(error_response(StatusCode::CONFLICT,"AUTOMATION_RUN_IN_FLIGHT","this automation is already running"));
            };
            let operation_id = state.jobs.create(transaction,RUN_KIND,automation.owner_device_id,Some(&automation.name),
                &json!({"automation_id":id,"run_id":run_id,"trigger":"manual","notify":automation.notify}).to_string())?;
            store::attach_operation(transaction,run_id,operation_id)?;
            let body = state.jobs.get(transaction,operation_id)?.and_then(|row|serde_json::to_value(row).ok())
                .unwrap_or_else(||json!({"id":operation_id,"kind":RUN_KIND,"state":"queued"}));
            claimed = Some((automation,run_id));
            Ok(crate::idempotency::StoredResponse {status:StatusCode::ACCEPTED,body,operation_id:Some(operation_id)})
        }).map_err(|error|error.envelope())?
    };
    if result.created
        && let Some((automation, run_id)) = claimed
    {
        let worker_state = state.clone();
        tokio::spawn(async move {
            scheduler::execute(&worker_state, automation, run_id).await;
        });
    }
    Ok(crate::idempotency::json_response(&result))
}

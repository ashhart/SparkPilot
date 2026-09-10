use super::*;

pub(super) fn event_error(status: StatusCode, code: &str, message: &str) -> Response {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
        .into_response()
}

pub(super) fn last_event_cursor(headers: &HeaderMap) -> Result<Option<i64>, &'static str> {
    let mut values = headers.get_all("last-event-id").iter();
    let Some(value) = values.next() else {
        return Ok(None);
    };
    if values.next().is_some() {
        return Err("Last-Event-ID must appear once");
    }
    let raw = value
        .to_str()
        .map_err(|_| "Last-Event-ID must be a nonnegative event sequence")?;
    if raw.is_empty() || !raw.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("Last-Event-ID must be a nonnegative event sequence");
    }
    let cursor = raw
        .parse::<i64>()
        .map_err(|_| "Last-Event-ID is outside the supported sequence range")?;
    Ok(Some(cursor))
}

/// Filter every replayed and live event by the viewer's role, device identity and project memberships.
pub async fn stream_events(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    headers: HeaderMap,
) -> Result<
    Sse<
        impl tokio_stream::Stream<Item = Result<axum::response::sse::Event, std::convert::Infallible>>,
    >,
    Response,
> {
    let cursor = last_event_cursor(&headers)
        .map_err(|message| event_error(StatusCode::BAD_REQUEST, "INVALID_REQUEST", message))?;

    // Subscribe before reading replay state, then deduplicate by high-water mark so racing events cannot be lost.
    let receiver = state.events.subscribe();
    let database = state.database.as_ref().ok_or_else(|| {
        event_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "INTERNAL_ERROR",
            "event storage is unavailable",
        )
    })?;
    let viewer = {
        let conn = database.lock();
        let projects =
            crate::store::project_ids_for_device(&conn, &principal.device_id).map_err(|error| {
                tracing::error!(%error, "event viewer membership lookup failed");
                event_error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "event visibility could not be resolved",
                )
            })?;
        crate::events::Viewer::new(
            principal.device_id,
            crate::capability::Role::parse(&principal.role),
            projects,
        )
    };
    let snapshot = {
        let conn = database.lock();
        crate::events::retained_public_after(&conn, cursor).map_err(|error| match error {
            crate::events::ReplayError::CursorExpired => event_error(
                StatusCode::CONFLICT,
                "EVENT_CURSOR_EXPIRED",
                "the requested event cursor is older than retained history",
            ),
            crate::events::ReplayError::CursorInFuture => event_error(
                StatusCode::BAD_REQUEST,
                "INVALID_REQUEST",
                "Last-Event-ID is newer than the current event sequence",
            ),
            crate::events::ReplayError::EventTooLarge(sequence) => {
                tracing::error!(sequence, "oversized retained event blocks safe replay");
                event_error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "a retained event exceeds the stream frame limit",
                )
            }
            crate::events::ReplayError::Database(error) => {
                tracing::error!(%error, "failed to read retained events");
                event_error(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_ERROR",
                    "retained events could not be read",
                )
            }
        })?
    };

    Ok(Sse::new(crate::events::resumed_stream(
        snapshot,
        receiver,
        database.clone(),
        viewer,
    )))
}

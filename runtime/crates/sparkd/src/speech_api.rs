//! Authenticated speech and package-approved optional Kokoro lifecycle.
use crate::{
    auth::{AuthenticatedRequest, Principal},
    capability::Capability,
    idempotency::IdempotencyRequest,
    state::AppState,
};
use axum::{
    Json,
    body::Body,
    extract::{Extension, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use spark_privd::{
    kokoro,
    protocol::{KokoroAction, PrivilegedOperation},
};
use std::time::Duration;

static SERVICE: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());
static SPEECH: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);
const MAX_AUDIO: usize = 32 * 1024 * 1024;
type Failure = (StatusCode, Json<Value>);
fn failure(status: StatusCode, code: &str) -> Failure {
    (
        status,
        Json(
            json!({"error":{"code":code,"message":"Kokoro voice service is unavailable","request_id":crate::route::current_request_id()}}),
        ),
    )
}

pub async fn status(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
) -> Result<Json<Value>, Failure> {
    state
        .require(&principal, Capability::NodeRead)
        .resource("services/kokoro")
        .check()?;
    let client = state
        .privileged
        .clone()
        .ok_or_else(|| failure(StatusCode::SERVICE_UNAVAILABLE, "KOKORO_UNAVAILABLE"))?;
    let response = tokio::task::spawn_blocking(move || {
        client.call_bounded(
            PrivilegedOperation::KokoroService {
                request_id: uuid::Uuid::new_v4(),
                action: KokoroAction::Status,
            },
            Duration::from_secs(3),
        )
    })
    .await
    .map_err(|_| failure(StatusCode::SERVICE_UNAVAILABLE, "KOKORO_STATUS_UNAVAILABLE"))?
    .map_err(|_| failure(StatusCode::SERVICE_UNAVAILABLE, "KOKORO_STATUS_UNAVAILABLE"))?;
    if !response.accepted {
        return Err(failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "KOKORO_STATUS_UNAVAILABLE",
        ));
    }
    let mut value = response.details;
    value["available_revision"] = json!(kokoro::REVISION);
    value["available_image"] = json!(kokoro::IMAGE);
    value["update_available"] =
        json!(value["installed"] == true && value["image"] != kokoro::IMAGE);
    value["voices"] = json!(kokoro::VOICES);
    value["memory_limit_bytes"] = json!(kokoro::MEMORY_BYTES);
    Ok(Json(value))
}

macro_rules! lifecycle {
    ($name:ident, $action:ident, $route:literal, $kind:literal, $stage:literal) => {
        pub async fn $name(State(state): State<AppState>, Extension(principal): Extension<Principal>,
            Extension(authenticated): Extension<AuthenticatedRequest>, idempotency: IdempotencyRequest, headers: HeaderMap
        ) -> Result<(StatusCode, Json<Value>), Failure> {
            let client = state.privileged.clone().ok_or_else(|| failure(StatusCode::SERVICE_UNAVAILABLE,"KOKORO_UNAVAILABLE"))?;
            crate::appliance_api::enqueue_operation(state, principal, authenticated, idempotency, headers,
                $route, $kind, json!({"service_id":"kokoro","revision":kokoro::REVISION}), None,
                move |operation_id, lease| {
                    let _guard = SERVICE.blocking_write();
                    // Name the opaque privileged-install stage so the app can show meaningful progress.
                    let _ = lease.set_stage($stage, None);
                    let result = client.call(PrivilegedOperation::KokoroService { request_id: operation_id, action: KokoroAction::$action });
                    crate::appliance_api::finish_privileged(lease, result, json!({"service_id":"kokoro"}), "KOKORO_OPERATION_FAILED");
                }
            ).await
        }
    };
}
lifecycle!(
    install,
    Install,
    "/api/v1/services/kokoro/install",
    "service.kokoro.install",
    "pulling_image"
);
lifecycle!(
    update,
    Update,
    "/api/v1/services/kokoro/update",
    "service.kokoro.update",
    "pulling_image"
);
lifecycle!(
    remove,
    Remove,
    "/api/v1/services/kokoro/remove",
    "service.kokoro.remove",
    "removing"
);

lifecycle!(
    enable,
    Enable,
    "/api/v1/services/kokoro/enable",
    "service.kokoro.enable",
    "starting"
);
lifecycle!(
    disable,
    Disable,
    "/api/v1/services/kokoro/disable",
    "service.kokoro.disable",
    "stopping"
);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SpeechRequest {
    model: String,
    input: String,
    voice: String,
    response_format: String,
    speed: f64,
}
impl SpeechRequest {
    fn valid(&self) -> bool {
        self.model == "kokoro"
            && self.response_format == "wav"
            && kokoro::VOICES.contains(&self.voice.as_str())
            && self.speed.is_finite()
            && (0.75..=1.25).contains(&self.speed)
            && !self.input.trim().is_empty()
            && self.input.len() <= 12_000
            && !self
                .input
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\t' | '\r'))
    }
}

pub async fn speech(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Json(request): Json<SpeechRequest>,
) -> Result<Response, Failure> {
    state
        .require(&principal, Capability::InferenceRun)
        .resource("audio/speech")
        .check()?;
    if !request.valid() {
        return Err(failure(
            StatusCode::UNPROCESSABLE_ENTITY,
            "INVALID_SPEECH_REQUEST",
        ));
    }
    let _permit = SPEECH
        .try_acquire()
        .map_err(|_| failure(StatusCode::TOO_MANY_REQUESTS, "KOKORO_BUSY"))?;
    let _service = SERVICE
        .try_read()
        .map_err(|_| failure(StatusCode::SERVICE_UNAVAILABLE, "KOKORO_UPDATING"))?;
    let Json(details) = status(State(state), Extension(principal)).await?;
    if details["installed"] != true || details["running"] != true || details["healthy"] != true {
        return Err(failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "KOKORO_UNAVAILABLE",
        ));
    }
    // Keep admission held until the upstream finishes even if the caller disconnects.
    tokio::spawn(async move {
    let (_permit, _service) = (_permit, _service);
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|_| failure(StatusCode::SERVICE_UNAVAILABLE, "KOKORO_UNAVAILABLE"))?;
    let mut upstream = client.post(format!("http://127.0.0.1:{}/v1/audio/speech",kokoro::PORT))
        .json(&json!({"model":"kokoro","input":request.input,"voice":request.voice,"response_format":"wav","speed":request.speed,"stream":false}))
        .send().await.map_err(|_| failure(StatusCode::SERVICE_UNAVAILABLE,"KOKORO_UNAVAILABLE"))?;
    if !upstream.status().is_success() {
        return Err(failure(StatusCode::BAD_GATEWAY, "KOKORO_SYNTHESIS_FAILED"));
    }
    if upstream
        .content_length()
        .is_some_and(|n| n > MAX_AUDIO as u64)
    {
        return Err(failure(StatusCode::BAD_GATEWAY, "KOKORO_AUDIO_TOO_LARGE"));
    }
    let mut audio = Vec::new();
    while let Some(chunk) = upstream
        .chunk()
        .await
        .map_err(|_| failure(StatusCode::BAD_GATEWAY, "KOKORO_SYNTHESIS_FAILED"))?
    {
        if audio.len().saturating_add(chunk.len()) > MAX_AUDIO {
            return Err(failure(StatusCode::BAD_GATEWAY, "KOKORO_AUDIO_TOO_LARGE"));
        }
        audio.extend_from_slice(&chunk);
    }
    normalize_wav(&mut audio).map_err(|_| failure(StatusCode::BAD_GATEWAY, "KOKORO_AUDIO_INVALID"))?;
    Ok((
        [("content-type", "audio/wav"), ("cache-control", "no-store")],
        Body::from(audio),
    )
        .into_response())
    }).await.map_err(|_| failure(StatusCode::BAD_GATEWAY, "KOKORO_SYNTHESIS_FAILED"))?
}

/// Replace ffmpeg's unknown RIFF/data lengths after buffering so Apple playback can determine WAV duration.
fn normalize_wav(audio: &mut [u8]) -> Result<(), ()> {
    if audio.len() < 44
        || audio.len() > MAX_AUDIO
        || &audio[..4] != b"RIFF"
        || &audio[8..12] != b"WAVE"
    {
        return Err(());
    }
    let mut offset = 12;
    let mut format_ok = false;
    while offset + 8 <= audio.len() {
        let length =
            u32::from_le_bytes(audio[offset + 4..offset + 8].try_into().map_err(|_| ())?) as usize;
        let start = offset + 8;
        match &audio[offset..offset + 4] {
            b"fmt " => {
                if length < 16 || start + length > audio.len() {
                    return Err(());
                }
                format_ok = audio[start..start + 4] == [1, 0, 1, 0]
                    && audio[start + 4..start + 8] == 24_000_u32.to_le_bytes()
                    && audio[start + 12..start + 16] == [2, 0, 16, 0];
            }
            b"data" => {
                let actual = audio.len() - start;
                if !format_ok
                    || actual == 0
                    || !actual.is_multiple_of(2)
                    || (length != u32::MAX as usize && length != actual)
                {
                    return Err(());
                }
                audio[offset + 4..offset + 8].copy_from_slice(&(actual as u32).to_le_bytes());
                let riff_length = (audio.len() - 8) as u32;
                audio[4..8].copy_from_slice(&riff_length.to_le_bytes());
                return Ok(());
            }
            _ => {}
        }
        offset = start
            .checked_add(length)
            .and_then(|v| v.checked_add(length % 2))
            .ok_or(())?;
    }
    Err(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> SpeechRequest {
        SpeechRequest {
            model: "kokoro".into(),
            input: "Hello, ready when you are.".into(),
            voice: "af_heart".into(),
            response_format: "wav".into(),
            speed: 1.0,
        }
    }
    #[test]
    fn streamed_wav_gets_a_real_duration_and_malformed_audio_is_refused() {
        let mut wav = b"RIFF\xff\xff\xff\xffWAVEfmt \x10\0\0\0\x01\0\x01\0\xc0\x5d\0\0\x80\xbb\0\0\x02\0\x10\0data\xff\xff\xff\xff\0\0\x01\0".to_vec();
        normalize_wav(&mut wav).unwrap();
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 40);
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 4);
        let mut truncated = wav.clone();
        truncated.pop();
        assert!(normalize_wav(&mut truncated).is_err());
        wav[20] = 3;
        assert!(normalize_wav(&mut wav).is_err());
    }
    #[test]
    fn refuses_arbitrary_models_voices_formats_and_resource_abuse() {
        assert!(request().valid());
        for voice in kokoro::VOICES {
            let mut r = request();
            r.voice = (*voice).into();
            assert!(r.valid(), "approved voice {voice} must be usable");
        }
        for voice in [
            "af_nicole",
            "af_heart+af_bella",
            "af_heart+af_nicole",
            "af_heart+af_sarah",
            "af_heart+../../voice.wav",
            "af_heart+unknown",
            "af_heart(100)+af_bella(1)",
        ] {
            let mut r = request();
            r.voice = voice.into();
            assert!(
                !r.valid(),
                "only the approved individual voices are accepted"
            );
        }
        let mut r = request();
        r.voice = "../../voice.wav".into();
        assert!(!r.valid());
        let mut r = request();
        r.model = "other".into();
        assert!(!r.valid());
        let mut r = request();
        r.input = "x".repeat(12_001);
        assert!(!r.valid());
        let mut r = request();
        r.speed = f64::NAN;
        assert!(!r.valid());
        let mut r = request();
        r.input = "\0".into();
        assert!(!r.valid());
        assert!(serde_json::from_value::<SpeechRequest>(json!({"model":"kokoro","input":"hi","voice":"af_heart","response_format":"wav","speed":1.0,"voice_url":"http://evil"})).is_err());
    }
}

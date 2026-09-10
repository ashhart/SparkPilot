//! Pin speech execution to the packaged release; callers cannot choose images, mounts, commands or ports.
pub const IMAGE: &str = "ghcr.io/remsky/kokoro-fastapi-gpu@sha256:3c819f71b54c9e60f18c90f47b920d3219994610c99e1e3a468330022984e368";
pub const REVISION: &str = "2026-09-04.1";
pub const CONTAINER: &str = "spark-kokoro";
pub const PREVIOUS: &str = "spark-kokoro-previous";
pub const PORT: u16 = 18082;
pub const MEMORY_BYTES: u64 = 4 * 1024 * 1024 * 1024;
pub const VOICES: &[&str] = &[
    "af_heart",
    "af_bella",
    "af_sarah",
    "af_kore",
    "am_fenrir",
    "am_puck",
    "bm_fable",
    "am_adam",
    "am_michael",
    "bf_emma",
    "bm_george",
];

pub fn launch_args(image: &str) -> Vec<String> {
    [
        "run",
        "-d",
        "--name",
        CONTAINER,
        "--label",
        "spark.service=kokoro",
        "--label",
        "spark.local=true",
        "--restart",
        "unless-stopped",
        "--network",
        "spark-inference-isolated",
        "--dns=127.0.0.1",
        "--publish",
        "127.0.0.1:18082:8880",
        "--gpus",
        "all",
        "--user",
        "1001:1001",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "4g",
        "--memory-swap",
        "4g",
        "--cpus",
        "4",
        "--pids-limit",
        "256",
        "--tmpfs",
        "/tmp:rw,exec,nosuid,nodev,size=512m,uid=1001,gid=1001",
        "--tmpfs",
        "/app/api/temp_files:rw,nosuid,nodev,noexec,size=128m,uid=1001,gid=1001",
        "--tmpfs",
        "/home/appuser/.cache:rw,nosuid,nodev,size=256m,uid=1001,gid=1001",
        "--env",
        "HF_HUB_OFFLINE=1",
        "--env",
        "TRANSFORMERS_OFFLINE=1",
        "--env",
        "ENABLE_WEB_PLAYER=false",
        "--env",
        "CORS_ENABLED=false",
        "--env",
        "ALLOW_LOCAL_VOICE_SAVING=false",
        "--env",
        "ENABLE_VOICE_TAGS=false",
        "--env",
        "OMP_NUM_THREADS=4",
        "--env",
        "API_LOG_LEVEL=WARNING",
        "--env",
        "DEFAULT_VOICE=af_heart",
        "--env",
        "TARGET_MIN_TOKENS=175",
        "--env",
        "TARGET_MAX_TOKENS=250",
        image,
        "python",
        "-m",
        "uvicorn",
        "api.src.main:app",
        "--host",
        "0.0.0.0",
        "--port",
        "8880",
        "--log-level",
        "warning",
        "--no-access-log",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn speech_has_fixed_loopback_isolation_and_a_digest_pin() {
        let args = launch_args(IMAGE);
        assert!(IMAGE.contains("@sha256:"));
        assert!(args.contains(&"127.0.0.1:18082:8880".into()));
        for value in [
            "--read-only",
            "no-new-privileges",
            "1001:1001",
            "HF_HUB_OFFLINE=1",
            "4g",
        ] {
            assert!(args.contains(&value.into()));
        }
        assert!(
            !args
                .iter()
                .any(|v| v.contains("docker.sock") || v == "--privileged")
        );
    }
}

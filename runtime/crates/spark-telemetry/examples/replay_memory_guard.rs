//! Replay hardware headroom readings through the production guard without running an engine.
use spark_telemetry::{MemoryPolicy, MemorySignals, ObservationContext, PressureStateMachine};
use std::{error::Error, fs, time::Duration};

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 4 {
        return Err(
            "usage: replay_memory_guard TRACE.jsonl TOTAL_BYTES HEALTHY_AFTER_SECONDS".into(),
        );
    }
    let total: u64 = args[2].parse()?;
    let healthy_after: f64 = args[3].parse()?;
    if total == 0 || !healthy_after.is_finite() || healthy_after < 0.0 {
        return Err("total bytes and healthy timestamp must describe a real run".into());
    }
    let mut machine = PressureStateMachine::new(MemoryPolicy::default());
    let mut transitions = Vec::new();
    let mut previous: Option<(f64, u64, u64)> = None;
    let mut complete_signals = true;
    for line in fs::read_to_string(&args[1])?.lines() {
        let row: serde_json::Value = serde_json::from_str(line)?;
        let elapsed = row["elapsed"].as_f64().ok_or("missing elapsed seconds")?;
        let available = row["available"].as_u64().ok_or("missing available bytes")?;
        if available > total {
            return Err("available memory exceeds host total".into());
        }
        let mut signals = MemorySignals::calm(total).with_available(available);
        let oom_kills = row["oom_kills"].as_u64().unwrap_or(0);
        complete_signals &= row["oom_kills"].is_u64()
            && row["psi_some_avg10"].is_f64()
            && row["psi_full_avg10"].is_f64();
        signals.psi_some_avg10 = row["psi_some_avg10"].as_f64().unwrap_or(0.0);
        signals.psi_full_avg10 = row["psi_full_avg10"].as_f64().unwrap_or(0.0);
        if let Some((last_time, last_available, last_oom)) = previous {
            if elapsed <= last_time {
                return Err("trace timestamps must increase".into());
            }
            signals.available_drop_bytes_per_second =
                (last_available.saturating_sub(available) as f64 / (elapsed - last_time)) as u64;
            signals.kernel_oom_event = oom_kills > last_oom;
        }
        previous = Some((elapsed, available, oom_kills));
        if let Some(transition) = machine.observe(
            &signals,
            ObservationContext {
                engine_active: true,
                engine_loading: elapsed < healthy_after,
            },
            Duration::try_from_secs_f64(elapsed)?,
        ) {
            transitions.push(serde_json::json!({
                "elapsed": elapsed,
                "available_bytes": available,
                "state": transition.to.as_str(),
                "action": format!("{:?}", transition.action),
            }));
        }
    }
    if previous.is_none() {
        return Err("empty memory trace".into());
    }
    println!(
        "{}",
        serde_json::json!({
            "scope": "Memory guard replay only; engine actions and thermal protection need hardware qualification",
            "psi_and_oom_recorded": complete_signals,
            "transitions": transitions,
            "final_state": machine.state().as_str(),
        })
    );
    Ok(())
}

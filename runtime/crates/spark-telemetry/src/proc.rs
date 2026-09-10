//! Read injectable procfs memory/CPU/PSI and Linux 4.20+ oom_kill counters; use the data directory for disk statistics.

use std::path::Path;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::signals::MemorySignals;
use crate::{
    AcceleratorSnapshot, HardwareSnapshot, InferenceSnapshot, StorageSnapshot, SystemMonitor,
    SystemSnapshot,
};

const ACCELERATOR_CACHE_TTL: Duration = Duration::from_secs(1);

/// Supply guard signals from production procfs or deterministic test monitors.
pub trait MemorySource: Send + Sync {
    fn signals(&self) -> MemorySignals;
}

/// Rolling sampler state used to derive velocities and CPU deltas.
#[derive(Debug, Default)]
struct SampleState {
    prev_available: Option<(u64, Instant)>,
    last_velocity: u64,
    prev_cpu: Option<(u64, u64)>, // (idle_ticks, total_ticks)
    prev_oom_kills: Option<u64>,
    last_accelerator: Option<(Instant, AcceleratorSnapshot)>,
}

/// Return None when procfs is unavailable, allowing development callers to select a fake monitor.
pub struct ProcMonitor {
    root: std::path::PathBuf,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    data_dir: std::path::PathBuf,
    state: Mutex<SampleState>,
}

impl ProcMonitor {
    pub fn new(root: impl AsRef<Path>, data_dir: impl AsRef<Path>) -> Option<Self> {
        let root = root.as_ref().to_path_buf();
        if !root.join("meminfo").is_file() {
            return None;
        }
        Some(Self {
            root,
            data_dir: data_dir.as_ref().to_path_buf(),
            state: Mutex::new(SampleState::default()),
        })
    }

    fn read(&self, name: &str) -> Option<String> {
        std::fs::read_to_string(self.root.join(name)).ok()
    }

    /// `(MemTotal, MemAvailable)` in bytes from `/proc/meminfo`.
    fn memory_bytes(&self) -> Option<(u64, u64)> {
        let text = self.read("meminfo")?;
        let mut total = None;
        let mut available = None;
        for line in text.lines() {
            if let Some(value) = parse_meminfo_kib(line, "MemTotal:") {
                total = Some(value);
            } else if let Some(value) = parse_meminfo_kib(line, "MemAvailable:") {
                available = Some(value);
            }
        }
        Some((total?, available?))
    }

    /// Read some/full avg10 percentages from the two PSI memory lines.
    fn psi(&self) -> (Option<f64>, Option<f64>) {
        let Some(text) = self.read("pressure/memory") else {
            return (None, None);
        };
        let mut some = None;
        let mut full = None;
        for line in text.lines() {
            let Some(value) = parse_psi_avg10(line) else {
                continue;
            };
            if line.starts_with("some") {
                some = Some(value);
            } else if line.starts_with("full") {
                full = Some(value);
            }
        }
        (some, full)
    }

    fn oom_kills(&self) -> u64 {
        self.read("vmstat")
            .and_then(|text| {
                text.lines().find_map(|line| {
                    let mut parts = line.split_whitespace();
                    match (parts.next(), parts.next()) {
                        (Some("oom_kill"), Some(count)) => count.parse().ok(),
                        _ => None,
                    }
                })
            })
            .unwrap_or(0)
    }

    fn load_average(&self) -> Option<f64> {
        let text = self.read("loadavg")?;
        text.split_whitespace().next()?.parse().ok()
    }

    fn uptime_seconds(&self) -> Option<u64> {
        let text = self.read("uptime")?;
        let value: f64 = text.split_whitespace().next()?.parse().ok()?;
        Some(value as u64)
    }

    /// Report the non-idle CPU fraction between consecutive reads, with zero on the first sample.
    fn cpu_utilisation(&self, sample: &mut SampleState) -> f64 {
        let Some(text) = self.read("stat") else {
            return 0.0;
        };
        let Some(line) = text.lines().next() else {
            return 0.0;
        };
        let ticks: Vec<u64> = line
            .split_whitespace()
            .skip(1)
            .filter_map(|t| t.parse().ok())
            .collect();
        if ticks.len() < 5 {
            return 0.0;
        }
        let idle = ticks[3] + ticks.get(4).copied().unwrap_or(0); // idle + iowait
        let total: u64 = ticks.iter().sum();
        match sample.prev_cpu.replace((idle, total)) {
            Some((prev_idle, prev_total)) if total > prev_total => {
                let idle_delta = idle.saturating_sub(prev_idle);
                let total_delta = total - prev_total;
                1.0 - (idle_delta as f64 / total_delta as f64)
            }
            _ => 0.0,
        }
    }

    #[cfg(target_os = "linux")]
    fn storage(&self) -> StorageSnapshot {
        use std::os::unix::ffi::OsStrExt;
        let c_path = std::ffi::CString::new(self.data_dir.as_os_str().as_bytes())
            .expect("data dir is a valid path");
        let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), &mut stats) };
        if rc != 0 {
            return StorageSnapshot::default();
        }
        StorageSnapshot {
            total_bytes: (stats.f_blocks as u64) * (stats.f_frsize as u64),
            free_bytes: (stats.f_bavail as u64) * (stats.f_frsize as u64),
        }
    }

    #[cfg(not(target_os = "linux"))]
    fn storage(&self) -> StorageSnapshot {
        StorageSnapshot::default()
    }

    fn accelerator(&self, sample: &mut SampleState) -> AcceleratorSnapshot {
        if let Some((sampled_at, snapshot)) = &sample.last_accelerator
            && sampled_at.elapsed() < ACCELERATOR_CACHE_TTL
        {
            return snapshot.clone();
        }

        let snapshot = nvidia_smi_output()
            .and_then(|output| parse_nvidia_smi_csv(&output))
            .unwrap_or_else(|| AcceleratorSnapshot {
                temperature_celsius: read_thermal_temperature(),
                ..AcceleratorSnapshot::default()
            });
        sample.last_accelerator = Some((Instant::now(), snapshot.clone()));
        snapshot
    }

    fn build_signals(&self, sample: &mut SampleState) -> MemorySignals {
        let memory = self.memory_bytes();
        if memory.is_none() {
            sample.prev_available = None;
        }
        let (total, available) = memory.unwrap_or((0, 0));
        let (psi_some, psi_full) = self.psi();

        if memory.is_none() {
            sample.last_velocity = 0;
        } else {
            let now = Instant::now();
            match sample.prev_available {
                Some((previous, at)) if now.duration_since(at) >= Duration::from_secs(1) => {
                    sample.last_velocity = (previous.saturating_sub(available) as f64
                        / now.duration_since(at).as_secs_f64())
                        as u64;
                    sample.prev_available = Some((available, now));
                }
                None => sample.prev_available = Some((available, now)),
                _ => {}
            }
        }
        let velocity = sample.last_velocity;

        let oom_kills = self.oom_kills();
        let kernel_oom_event = match sample.prev_oom_kills.replace(oom_kills) {
            Some(prev) => oom_kills > prev,
            None => false,
        };

        // Use cached accelerator temperature here; hardware() alone runs the bounded child probe, and cold or stale caches yield None.
        let gpu_celsius = sample
            .last_accelerator
            .as_ref()
            .and_then(|(_, snapshot)| snapshot.temperature_celsius);
        // Thermal zones need only small inline sysfs reads and remain unavailable on non-Linux hosts.
        let cpu_celsius = read_thermal_temperature();

        MemorySignals {
            available_bytes: available,
            total_bytes: total,
            // Convert Linux PSI percentages to guard ratios here; the hardware API retains percentages.
            psi_some_avg10: psi_some.unwrap_or(0.0) / 100.0,
            psi_full_avg10: psi_full.unwrap_or(0.0) / 100.0,
            available_drop_bytes_per_second: velocity,
            kernel_oom_event,
            gpu_celsius,
            cpu_celsius,
        }
    }
}

/// Bound driver probes; kill and reap any child that exceeds its deadline.
fn nvidia_smi_output() -> Option<String> {
    let mut child = Command::new("nvidia-smi")
        .args([
            "--query-gpu=utilization.gpu,temperature.gpu,power.draw,power.limit,memory.used,memory.total",
            "--format=csv,noheader,nounits",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                let output = child.wait_with_output().ok()?;
                return String::from_utf8(output.stdout).ok();
            }
            Ok(Some(_)) | Err(_) => return None,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

impl MemorySource for ProcMonitor {
    fn signals(&self) -> MemorySignals {
        let mut sample = self.state.lock().expect("proc monitor lock");
        self.build_signals(&mut sample)
    }
}

impl SystemMonitor for ProcMonitor {
    fn system(&self) -> SystemSnapshot {
        let mut sample = self.state.lock().expect("proc monitor lock");
        let (total, available) = self.memory_bytes().unwrap_or((0, 0));
        let cpu = self.cpu_utilisation(&mut sample);
        SystemSnapshot {
            unified_memory_total_bytes: total,
            unified_memory_available_bytes: available,
            // Normal is a procfs placeholder; sparkd must resolve actual pressure through guard::observed_pressure before reporting it.
            memory_pressure: crate::MemoryPressure::Normal,
            cpu_utilisation: cpu.clamp(0.0, 1.0),
            load_average_1m: self.load_average().unwrap_or(0.0),
            disk_free_bytes: self.storage().free_bytes,
            temperature_celsius: None,
            power_state: "normal".to_owned(),
            uptime_seconds: self.uptime_seconds().unwrap_or(0),
        }
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }

    fn hardware(&self) -> HardwareSnapshot {
        let mut sample = self.state.lock().expect("proc monitor lock");
        let (memory_psi_some_avg10, memory_psi_full_avg10) = self.psi();
        HardwareSnapshot {
            accelerator: self.accelerator(&mut sample),
            storage: self.storage(),
            memory_psi_some_avg10,
            memory_psi_full_avg10,
        }
    }
}

fn parse_optional_number(value: &str) -> Option<f64> {
    let value = value.trim();
    if value.is_empty() || value.eq_ignore_ascii_case("n/a") || value == "[N/A]" {
        None
    } else {
        value.parse().ok()
    }
}

fn parse_nvidia_smi_csv(output: &str) -> Option<AcceleratorSnapshot> {
    let mut fields = output.lines().next()?.split(',');
    let utilisation =
        parse_optional_number(fields.next()?).map(|value| (value / 100.0).clamp(0.0, 1.0));
    let temperature_celsius = parse_optional_number(fields.next()?);
    let power_draw_watts = parse_optional_number(fields.next()?);
    let power_limit_watts = parse_optional_number(fields.next()?);
    let memory_used_bytes = parse_optional_number(fields.next()?).and_then(mebibytes_to_bytes);
    let memory_total_bytes = parse_optional_number(fields.next()?).and_then(mebibytes_to_bytes);
    Some(AcceleratorSnapshot {
        utilisation,
        temperature_celsius,
        power_draw_watts,
        power_limit_watts,
        memory_used_bytes,
        memory_total_bytes,
    })
}

fn mebibytes_to_bytes(value: f64) -> Option<u64> {
    let bytes = value * 1_048_576.0;
    (value.is_finite() && value >= 0.0 && bytes <= u64::MAX as f64).then_some(bytes as u64)
}

#[cfg(target_os = "linux")]
fn read_thermal_temperature() -> Option<f64> {
    let entries = std::fs::read_dir("/sys/class/thermal").ok()?;
    entries
        .filter_map(Result::ok)
        .filter_map(|entry| std::fs::read_to_string(entry.path().join("temp")).ok())
        .filter_map(|value| value.trim().parse::<f64>().ok())
        .map(|value| {
            if value > 1_000.0 {
                value / 1_000.0
            } else {
                value
            }
        })
        .filter(|value| (0.0..=150.0).contains(value))
        .max_by(f64::total_cmp)
}

#[cfg(not(target_os = "linux"))]
fn read_thermal_temperature() -> Option<f64> {
    None
}

fn parse_meminfo_kib(line: &str, key: &str) -> Option<u64> {
    let rest = line.strip_prefix(key)?;
    let kib: u64 = rest.split_whitespace().next()?.parse().ok()?;
    Some(kib * 1024)
}

/// `avg10=` value within one PSI line.
fn parse_psi_avg10(line: &str) -> Option<f64> {
    line.split_whitespace()
        .find_map(|token| token.strip_prefix("avg10=")?.parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn synthetic_proc(tmp: &Path) -> std::path::PathBuf {
        let root = tmp.join("proc");
        fs::create_dir_all(root.join("pressure")).unwrap();
        fs::write(
            root.join("meminfo"),
            "MemTotal:       131914816 kB\nMemFree:         12345678 kB\nMemAvailable:    28743895 kB\n",
        )
        .unwrap();
        fs::write(
            root.join("pressure/memory"),
            "some avg10=0.12 avg60=0.10 avg300=0.08 total=123456789\nfull avg10=0.02 avg60=0.01 avg300=0.01 total=9876543\n",
        )
        .unwrap();
        fs::write(root.join("vmstat"), "pgfault 123\noom_kill 0\n").unwrap();
        fs::write(root.join("loadavg"), "1.24 1.10 0.98 3/1024 12345\n").unwrap();
        fs::write(root.join("uptime"), "84523.14 312456.67\n").unwrap();
        fs::write(root.join("stat"), "cpu  100 0 200 800 50 0 0 0 0 0\n").unwrap();
        root
    }

    #[test]
    fn kernel_psi_percentages_reach_guard_as_fractions() {
        use crate::classify::{MemoryAction, classify};
        use crate::signals::MemoryPolicy;

        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).unwrap();
        for (some, full, expected) in [
            ("0.20", "0.12", MemoryAction::Continue),
            ("30.00", "0.12", MemoryAction::StopAdmissions),
            ("30.00", "12.00", MemoryAction::GracefulUnload),
        ] {
            fs::write(
                root.join("pressure/memory"),
                format!("some avg10={some} avg60=0.00 avg300=0.00 total=0\nfull avg10={full} avg60=0.00 avg300=0.00 total=0\n"),
            ).unwrap();
            let signals = MemorySource::signals(&monitor);
            assert_eq!(
                classify(&signals, &MemoryPolicy::default()),
                expected,
                "kernel some={some}% full={full}% with {} bytes available",
                signals.available_bytes
            );
        }
    }

    #[test]
    fn parses_memory_and_psi_from_a_synthetic_tree() {
        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).expect("proc root accepted");

        let signals = MemorySource::signals(&monitor);
        assert_eq!(signals.total_bytes, 131_914_816 * 1024);
        assert_eq!(signals.available_bytes, 28_743_895 * 1024);
        assert_eq!(signals.psi_some_avg10, 0.0012);
        assert_eq!(signals.psi_full_avg10, 0.0002);
        assert!(!signals.kernel_oom_event);
    }

    #[test]
    fn system_snapshot_reads_load_uptime_and_disk_calls() {
        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).expect("proc root accepted");
        let snapshot = monitor.system();
        assert_eq!(snapshot.unified_memory_total_bytes, 131_914_816 * 1024);
        assert_eq!(snapshot.load_average_1m, 1.24);
        assert_eq!(snapshot.uptime_seconds, 84_523);
        assert!((0.0..=1.0).contains(&snapshot.cpu_utilisation));

        let hardware = monitor.hardware();
        assert_eq!(hardware.memory_psi_some_avg10, Some(0.12));
        assert_eq!(hardware.memory_psi_full_avg10, Some(0.02));
    }

    #[test]
    fn parses_accelerator_metrics_and_tolerates_unavailable_power() {
        let snapshot = parse_nvidia_smi_csv("73, 61, [N/A], 140.0, 24576, 131072\n").unwrap();
        assert_eq!(snapshot.utilisation, Some(0.73));
        assert_eq!(snapshot.temperature_celsius, Some(61.0));
        assert_eq!(snapshot.power_draw_watts, None);
        assert_eq!(snapshot.power_limit_watts, Some(140.0));
        assert_eq!(snapshot.memory_used_bytes, Some(24_576 * 1_048_576));
        assert_eq!(snapshot.memory_total_bytes, Some(131_072 * 1_048_576));
    }

    #[test]
    fn unavailable_accelerator_memory_and_psi_stay_unavailable() {
        let snapshot = parse_nvidia_smi_csv("73, 61, 48, 140.0, [N/A], [N/A]\n").unwrap();
        assert_eq!(snapshot.memory_used_bytes, None);
        assert_eq!(snapshot.memory_total_bytes, None);

        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        fs::remove_file(root.join("pressure/memory")).unwrap();
        let monitor = ProcMonitor::new(&root, tmp.path()).expect("proc root accepted");
        let hardware = monitor.hardware();
        assert_eq!(hardware.memory_psi_some_avg10, None);
        assert_eq!(hardware.memory_psi_full_avg10, None);
    }

    #[test]
    fn rapid_status_reads_do_not_turn_small_memory_deltas_into_an_emergency() {
        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).unwrap();
        let baseline = 16_u64 << 30;
        monitor.state.lock().unwrap().prev_available = Some((baseline, Instant::now()));
        fs::write(
            root.join("meminfo"),
            "MemTotal: 134217728 kB\nMemAvailable: 16646144 kB\n",
        )
        .unwrap();
        let signals = monitor.signals();
        assert!(signals.available_drop_bytes_per_second < 4_u64 << 30);
        assert_ne!(
            crate::classify::classify_with_velocity(&signals, &Default::default(), true),
            crate::classify::MemoryAction::EmergencyStop
        );
    }

    #[test]
    fn a_real_one_second_cliff_remains_visible_to_the_guard_after_other_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).unwrap();
        monitor.state.lock().unwrap().prev_available =
            Some((20_u64 << 30, Instant::now() - Duration::from_secs(1)));
        fs::write(
            root.join("meminfo"),
            "MemTotal: 134217728 kB\nMemAvailable: 14680064 kB\n",
        )
        .unwrap();
        let first = monitor.signals();
        monitor.system();
        let guard = monitor.signals();
        assert_eq!(
            first.available_drop_bytes_per_second,
            guard.available_drop_bytes_per_second
        );
        assert_eq!(
            crate::classify::classify_with_velocity(&guard, &Default::default(), true),
            crate::classify::MemoryAction::EmergencyStop
        );
    }

    #[test]
    fn oom_counter_increase_flips_the_event_flag() {
        let tmp = tempfile::tempdir().unwrap();
        let root = synthetic_proc(tmp.path());
        let monitor = ProcMonitor::new(&root, tmp.path()).expect("proc root accepted");
        assert!(!MemorySource::signals(&monitor).kernel_oom_event);
        fs::write(root.join("vmstat"), "pgfault 124\noom_kill 1\n").unwrap();
        assert!(MemorySource::signals(&monitor).kernel_oom_event);
    }

    #[test]
    fn missing_proc_root_is_rejected_so_callers_can_fall_back() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(ProcMonitor::new(tmp.path().join("absent"), tmp.path()).is_none());
    }
}

#[cfg(test)]
mod glm_missing_sensor {
    use super::*;
    #[test]
    fn an_unreadable_meminfo_does_not_stop_the_engine_or_invent_velocity() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("meminfo");
        let reading = "MemTotal: 134217728 kB\nMemAvailable: 67108864 kB\n";
        std::fs::write(&path, reading).unwrap();
        let monitor = ProcMonitor::new(root.path(), root.path()).unwrap();
        let mut machine = crate::pressure::PressureStateMachine::new(Default::default());
        let context = crate::pressure::ObservationContext {
            engine_active: true,
            engine_loading: false,
        };
        assert!(
            machine
                .observe(&monitor.signals(), context, Duration::ZERO)
                .is_none()
        );
        std::fs::remove_file(&path).unwrap();
        assert!(
            machine
                .observe(&monitor.signals(), context, Duration::from_secs(1))
                .is_none()
        );
        std::fs::write(&path, reading).unwrap();
        assert_eq!(monitor.signals().available_drop_bytes_per_second, 0);
    }
}

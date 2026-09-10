/// Controllable memory source; the scheduler reasons only about this value.
struct FixedMonitor {
    available_bytes: Arc<AtomicU64>,
}

impl FixedMonitor {
    fn new(available_bytes: u64) -> (Self, Arc<AtomicU64>) {
        let available = Arc::new(AtomicU64::new(available_bytes));
        (
            Self {
                available_bytes: available.clone(),
            },
            available,
        )
    }
}

impl SystemMonitor for FixedMonitor {
    fn system(&self) -> SystemSnapshot {
        SystemSnapshot {
            unified_memory_total_bytes: 240 << 30,
            unified_memory_available_bytes: self.available_bytes.load(Ordering::Relaxed),
            memory_pressure: MemoryPressure::Normal,
            cpu_utilisation: 0.10,
            load_average_1m: 0.5,
            disk_free_bytes: 100 << 30,
            temperature_celsius: Some(40.0),
            power_state: "normal".to_owned(),
            uptime_seconds: 100,
        }
    }

    fn inference(&self) -> InferenceSnapshot {
        InferenceSnapshot::default()
    }
}

struct StaticSource {
    available: Arc<AtomicU64>,
    total: u64,
}

impl spark_telemetry::MemorySource for StaticSource {
    fn signals(&self) -> spark_telemetry::MemorySignals {
        spark_telemetry::MemorySignals::calm(self.total)
            .with_available(self.available.load(Ordering::Relaxed))
    }
}

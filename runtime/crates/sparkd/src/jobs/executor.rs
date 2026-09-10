use super::*;

/// Bound worker slots and refuse saturation immediately to prevent unbounded thread or queue growth.
#[derive(Debug)]
pub struct WorkerPool {
    capacity: usize,
    in_flight: std::sync::atomic::AtomicUsize,
    admitted: std::sync::atomic::AtomicU64,
    rejected: std::sync::atomic::AtomicU64,
    high_water: std::sync::atomic::AtomicUsize,
}

/// Saturation metrics for the status surface (§27.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkerPoolMetrics {
    pub capacity: usize,
    pub in_flight: usize,
    pub admitted: u64,
    pub rejected: u64,
    pub high_water_mark: usize,
}

/// Return the admitted worker slot on every exit, including panic unwinding.
#[derive(Debug)]
pub struct WorkerSlot {
    pool: Arc<WorkerPool>,
}

impl Drop for WorkerSlot {
    fn drop(&mut self) {
        self.pool
            .in_flight
            .fetch_sub(1, std::sync::atomic::Ordering::AcqRel);
    }
}

impl WorkerPool {
    pub fn new(capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            // Clamp invalid zero capacity so the daemon retains a usable executor.
            capacity: capacity.max(1),
            in_flight: std::sync::atomic::AtomicUsize::new(0),
            admitted: std::sync::atomic::AtomicU64::new(0),
            rejected: std::sync::atomic::AtomicU64::new(0),
            high_water: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// Take a slot, or report saturation. Never blocks.
    pub fn try_admit(self: &Arc<Self>) -> Option<WorkerSlot> {
        use std::sync::atomic::Ordering;
        let mut current = self.in_flight.load(Ordering::Acquire);
        loop {
            if current >= self.capacity {
                self.rejected.fetch_add(1, Ordering::Relaxed);
                return None;
            }
            match self.in_flight.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => {
                    let taken = current + 1;
                    self.admitted.fetch_add(1, Ordering::Relaxed);
                    self.high_water.fetch_max(taken, Ordering::Relaxed);
                    return Some(WorkerSlot { pool: self.clone() });
                }
                Err(observed) => current = observed,
            }
        }
    }

    pub fn metrics(&self) -> WorkerPoolMetrics {
        use std::sync::atomic::Ordering;
        WorkerPoolMetrics {
            capacity: self.capacity,
            in_flight: self.in_flight.load(Ordering::Acquire),
            admitted: self.admitted.load(Ordering::Relaxed),
            rejected: self.rejected.load(Ordering::Relaxed),
            high_water_mark: self.high_water.load(Ordering::Relaxed),
        }
    }
}

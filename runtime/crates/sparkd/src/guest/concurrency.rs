//! Count a guest's in-flight requests in this process, because the concurrency limit is about live streams.

use std::collections::HashMap;
use std::sync::Arc;

use parking_lot::Mutex;

/// Live guest request counts, keyed by device.
#[derive(Debug, Clone, Default)]
pub struct GuestConcurrency {
    inner: Arc<Mutex<HashMap<uuid::Uuid, u32>>>,
}

/// Holds one guest request slot; dropping it releases the slot however the request ended.
#[derive(Debug)]
pub struct GuestSlot {
    inner: Arc<Mutex<HashMap<uuid::Uuid, u32>>>,
    device_id: uuid::Uuid,
}

impl GuestConcurrency {
    pub fn new() -> GuestConcurrency {
        GuestConcurrency::default()
    }

    /// How many requests this guest already has in flight.
    pub fn active(&self, device_id: &uuid::Uuid) -> u32 {
        self.inner.lock().get(device_id).copied().unwrap_or(0)
    }

    /// Take a slot for a guest whose policy has already admitted this request.
    pub fn acquire(&self, device_id: &uuid::Uuid) -> GuestSlot {
        *self.inner.lock().entry(*device_id).or_insert(0) += 1;
        GuestSlot {
            inner: self.inner.clone(),
            device_id: *device_id,
        }
    }

    /// Take a slot only while the guest is below its limit, so admission and counting cannot race.
    pub fn acquire_below(&self, device_id: &uuid::Uuid, limit: u32) -> Option<GuestSlot> {
        let mut counts = self.inner.lock();
        let count = counts.entry(*device_id).or_insert(0);
        if *count >= limit {
            return None;
        }
        *count += 1;
        Some(GuestSlot {
            inner: self.inner.clone(),
            device_id: *device_id,
        })
    }
}

impl Drop for GuestSlot {
    fn drop(&mut self) {
        let mut counts = self.inner.lock();
        match counts.get_mut(&self.device_id) {
            Some(count) if *count > 1 => *count -= 1,
            Some(_) => {
                counts.remove(&self.device_id);
            }
            None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_slot_is_released_however_the_request_ended() {
        let concurrency = GuestConcurrency::new();
        let device = uuid::Uuid::new_v4();
        assert_eq!(concurrency.active(&device), 0);
        {
            let _slot = concurrency.acquire(&device);
            assert_eq!(concurrency.active(&device), 1);
            let _second = concurrency.acquire(&device);
            assert_eq!(concurrency.active(&device), 2);
        }
        assert_eq!(concurrency.active(&device), 0);
    }

    #[test]
    fn admission_and_counting_happen_under_one_lock() {
        let concurrency = GuestConcurrency::new();
        let device = uuid::Uuid::new_v4();
        let first = concurrency.acquire_below(&device, 1);
        assert!(first.is_some());
        assert!(
            concurrency.acquire_below(&device, 1).is_none(),
            "the limit is enforced while the first slot is held"
        );
        drop(first);
        assert!(concurrency.acquire_below(&device, 1).is_some());
    }

    #[test]
    fn one_guest_does_not_spend_another_guests_slots() {
        let concurrency = GuestConcurrency::new();
        let first = uuid::Uuid::new_v4();
        let second = uuid::Uuid::new_v4();
        let _held = concurrency.acquire_below(&first, 1).expect("slot");
        assert!(concurrency.acquire_below(&second, 1).is_some());
    }
}

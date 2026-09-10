use super::container_stopped;

/// A gone container must not remain failed because cached weights delay memory recovery and block runtime updates.
#[test]
fn a_gone_container_is_stopped_whatever_memory_says() {
    assert!(container_stopped(true, false));
    // Still there after a stop: a real failure.
    assert!(!container_stopped(true, true));
    // The stop itself errored and the container survived.
    assert!(!container_stopped(false, true));
    // A failed stop remains a failure even if later inspection finds no container.
    assert!(!container_stopped(false, false));
}

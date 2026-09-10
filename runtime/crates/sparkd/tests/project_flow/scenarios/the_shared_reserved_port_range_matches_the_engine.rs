/// Pin shared and engine port ranges together so every parser and preview guard protects the actual listener.
#[test]
fn the_shared_reserved_port_range_matches_the_engine() {
    assert_eq!(
        spark_core::RESERVED_ENGINE_PORT_RANGE_START,
        sparkd::engine::INTERNAL_PORT_RANGE_START
    );
    assert_eq!(
        spark_core::RESERVED_ENGINE_PORT_RANGE_END,
        sparkd::engine::INTERNAL_PORT_RANGE_END
    );
}

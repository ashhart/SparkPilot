use std::sync::mpsc;
use std::time::Duration;

use nix::sys::stat::Mode;
use nix::unistd::mkfifo;

use super::*;

#[test]
fn fifo_source_is_rejected_without_blocking_the_root_worker() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("swapped-source");
    let destination = directory.path().join("sealed-destination");
    mkfifo(&source, Mode::from_bits_truncate(0o600)).unwrap();

    let director = RuntimeUpdateDirector::new(nix::unistd::geteuid().as_raw());
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        sender
            .send(director.copy_sealed(&source, &destination))
            .unwrap();
    });

    let result = receiver
        .recv_timeout(Duration::from_millis(250))
        .expect("opening a replaced FIFO must never wait for a writer");
    assert!(result.is_err(), "a FIFO must not enter the sealed tree");
}

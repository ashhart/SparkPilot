use super::*;
use std::collections::VecDeque;

/// Exactly one PTY reader per process; every window gets its own ordered subscription.
pub struct TerminalOutput {
    state: Mutex<OutputState>,
    pub changed: tokio::sync::watch::Sender<u64>,
}

#[derive(Default)]
struct OutputState {
    frames: VecDeque<(u64, String)>,
    next: u64,
    bytes: usize,
    closed: bool,
}

impl TerminalOutput {
    pub(super) fn start(session: PtyHandle) -> Arc<Self> {
        let output = Arc::new(Self {
            state: Mutex::new(OutputState::default()),
            changed: tokio::sync::watch::channel(0).0,
        });
        let weak = Arc::downgrade(&output);
        std::thread::spawn(move || {
            let mut decoder = TerminalUTF8::default();
            while let Some(output) = weak.upgrade() {
                if output.state.lock().closed {
                    break;
                }
                let result = session.lock().read();
                match result {
                    Ok(bytes) if bytes.is_empty() => {
                        drop(output);
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Ok(bytes) => output.append(decoder.push(&bytes)),
                    Err(_) => {
                        output.close();
                        break;
                    }
                }
            }
        });
        output
    }

    fn append(&self, text: String) {
        if text.is_empty() {
            return;
        }
        let mut state = self.state.lock();
        state.next += 1;
        let next = state.next;
        state.bytes += text.len();
        state.frames.push_back((next, text));
        while state.bytes > 1_048_576 {
            if let Some((_, removed)) = state.frames.pop_front() {
                state.bytes -= removed.len();
            }
        }
        self.changed.send_replace(next);
    }

    pub fn snapshot(&self, after: u64) -> (Vec<(u64, String)>, bool) {
        let state = self.state.lock();
        (
            state
                .frames
                .iter()
                .filter(|(id, _)| *id > after)
                .cloned()
                .collect(),
            state.closed,
        )
    }

    pub fn is_closed(&self) -> bool {
        self.state.lock().closed
    }

    pub fn close(&self) {
        let mut state = self.state.lock();
        state.closed = true;
        self.changed.send_replace(state.next);
    }
}

/// Preserve UTF-8 scalars split by kernel reads; malformed bytes still make forward progress.
#[derive(Default)]
struct TerminalUTF8 {
    pending: Vec<u8>,
}
impl TerminalUTF8 {
    fn push(&mut self, bytes: &[u8]) -> String {
        self.pending.extend_from_slice(bytes);
        let mut result = String::new();
        loop {
            match std::str::from_utf8(&self.pending) {
                Ok(text) => {
                    result.push_str(text);
                    self.pending.clear();
                    break;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    result.push_str(std::str::from_utf8(&self.pending[..valid]).unwrap());
                    self.pending.drain(..valid);
                    if let Some(length) = error.error_len() {
                        result.push('\u{fffd}');
                        self.pending.drain(..length);
                    } else {
                        break;
                    }
                }
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn every_unicode_split_retains_terminal_bytes() {
        let source = "\x1b[38;2;1;2;3mλ 👩🏽‍💻\r\n東京\x1b[0m";
        for split in 0..source.len() {
            let mut decoder = TerminalUTF8::default();
            let first = decoder.push(&source.as_bytes()[..split]);
            assert_eq!(first + &decoder.push(&source.as_bytes()[split..]), source);
        }
    }
    #[test]
    fn malformed_input_does_not_swallow_the_next_prompt() {
        let mut decoder = TerminalUTF8::default();
        assert_eq!(decoder.push(&[0xff, b'>', b' ']), "\u{fffd}> ");
    }
}

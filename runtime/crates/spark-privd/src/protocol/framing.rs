use super::*;

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("request exceeds the {MAX_REQUEST_BYTES} byte limit")]
    RequestTooLarge,
    #[error("invalid frame: {0}")]
    InvalidFrame(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Parse a request extended with a 4-byte big-endian length header.
pub fn parse_request(bytes: &[u8]) -> Result<PrivilegedOperation, ProtocolError> {
    if bytes.len() < FRAME_HEADER_BYTES {
        return Err(ProtocolError::InvalidFrame("missing length header".into()));
    }
    let length = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if length > MAX_REQUEST_BYTES {
        return Err(ProtocolError::RequestTooLarge);
    }
    let payload = &bytes[FRAME_HEADER_BYTES..];
    if payload.len() != length {
        return Err(ProtocolError::InvalidFrame(format!(
            "declared {length} bytes, got {}",
            payload.len()
        )));
    }
    Ok(serde_json::from_slice(payload)?)
}

/// Reject oversized declared frames before allocating their payload buffers.
pub fn read_request<R: Read>(reader: &mut R) -> Result<PrivilegedOperation, ProtocolError> {
    let mut header = [0u8; FRAME_HEADER_BYTES];
    reader.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_REQUEST_BYTES {
        return Err(ProtocolError::RequestTooLarge);
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(serde_json::from_slice(&payload)?)
}

/// Write one length-delimited response (bounded).
pub fn write_response<W: Write>(
    writer: &mut W,
    response: &PrivilegedResponse,
) -> Result<(), ProtocolError> {
    write_framed(writer, response)
}

/// Write one length-delimited request (bounded).
pub fn write_request<W: Write>(
    writer: &mut W,
    request: &PrivilegedOperation,
) -> Result<(), ProtocolError> {
    write_framed(writer, request)
}

pub(super) fn write_framed<W: Write, T: Serialize>(
    writer: &mut W,
    value: &T,
) -> Result<(), ProtocolError> {
    let json = serde_json::to_vec(value)?;
    if json.len() > MAX_REQUEST_BYTES {
        return Err(ProtocolError::InvalidFrame("message too large".into()));
    }
    writer.write_all(&(json.len() as u32).to_be_bytes())?;
    writer.write_all(&json)?;
    writer.flush()?;
    Ok(())
}

/// Attach an optional descriptor to the four-byte header while preserving descriptor-free framing compatibility.
pub fn write_response_with_fd(
    stream: &std::os::unix::net::UnixStream,
    response: &PrivilegedResponse,
    fd: Option<std::os::fd::RawFd>,
) -> Result<(), ProtocolError> {
    let json = serde_json::to_vec(response)?;
    if json.len() > MAX_RESPONSE_BYTES {
        return Err(ProtocolError::InvalidFrame("message too large".into()));
    }
    crate::fdpass::send_with_fd(stream, &(json.len() as u32).to_be_bytes(), fd)?;
    let mut writer = stream;
    writer.write_all(&json)?;
    writer.flush()?;
    Ok(())
}

/// Read one length-delimited response and any descriptor sent with it.
pub fn read_response_with_fd(
    stream: &std::os::unix::net::UnixStream,
) -> Result<(PrivilegedResponse, Option<std::os::fd::OwnedFd>), ProtocolError> {
    let mut header = [0u8; FRAME_HEADER_BYTES];
    let descriptor = crate::fdpass::recv_exact_with_fd(stream, &mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_RESPONSE_BYTES {
        return Err(ProtocolError::InvalidFrame("response too large".into()));
    }
    let mut payload = vec![0u8; length];
    let mut reader = stream;
    reader.read_exact(&mut payload)?;
    Ok((serde_json::from_slice(&payload)?, descriptor))
}

/// Read one length-delimited response (bounded).
pub fn read_response<R: Read>(reader: &mut R) -> Result<PrivilegedResponse, ProtocolError> {
    let mut header = [0u8; FRAME_HEADER_BYTES];
    reader.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_RESPONSE_BYTES {
        return Err(ProtocolError::InvalidFrame("response too large".into()));
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload)?;
    Ok(serde_json::from_slice(&payload)?)
}

/// Reject repeated request IDs with both a retention window and a count limit.
#[derive(Debug, Default)]
pub struct RequestIdTracker {
    seen: VecDeque<(Uuid, std::time::Instant)>,
}

impl RequestIdTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Return false for IDs already observed within the retention window.
    pub fn observe(&mut self, id: Uuid) -> bool {
        let now = std::time::Instant::now();
        while let Some((_, at)) = self.seen.front() {
            if now.duration_since(*at) > DUPLICATE_RETENTION {
                self.seen.pop_front();
            } else {
                break;
            }
        }
        if self.seen.iter().any(|(seen, _)| *seen == id) {
            return false;
        }
        self.seen.push_back((id, now));
        while self.seen.len() > DUPLICATE_WINDOW {
            self.seen.pop_front();
        }
        true
    }
}

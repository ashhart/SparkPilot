//! Send trusted host mutations through the typed privileged client rather than arbitrary commands.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use spark_privd::protocol::{
    PrivilegedOperation, PrivilegedResponse, read_response, write_request,
};
use thiserror::Error;

pub const DEFAULT_SOCKET: &str = "/run/spark-runtime/spark-privd.sock";

#[derive(Debug, Error)]
pub enum PrivilegedClientError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("protocol error: {0}")]
    Protocol(#[from] spark_privd::protocol::ProtocolError),
    #[error("socket path unavailable at {0}")]
    MissingSocket(PathBuf),
}

#[derive(Debug, Clone)]
pub struct PrivilegedClient {
    socket: PathBuf,
}

impl PrivilegedClient {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub fn default_socket() -> Self {
        Self::new(DEFAULT_SOCKET)
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket
    }

    /// Await a bounded response body without a deadline for legitimate long-running image, stop or power operations.
    pub fn call(
        &self,
        operation: PrivilegedOperation,
    ) -> Result<PrivilegedResponse, PrivilegedClientError> {
        self.exchange(operation, None)
    }

    /// Bound the socket round trip for live probes; long-running operations retain the unbounded-duration call path.
    pub fn call_bounded(
        &self,
        operation: PrivilegedOperation,
        deadline: Duration,
    ) -> Result<PrivilegedResponse, PrivilegedClientError> {
        self.exchange(operation, Some(deadline))
    }

    pub fn call_with_fd(
        &self,
        operation: PrivilegedOperation,
    ) -> Result<(PrivilegedResponse, Option<std::os::fd::OwnedFd>), PrivilegedClientError> {
        if !self.socket.exists() {
            return Err(PrivilegedClientError::MissingSocket(self.socket.clone()));
        }
        let mut stream = UnixStream::connect(&self.socket)?;
        write_request(&mut stream, &operation)?;
        stream.flush()?;
        Ok(spark_privd::protocol::read_response_with_fd(&stream)?)
    }

    fn exchange(
        &self,
        operation: PrivilegedOperation,
        deadline: Option<Duration>,
    ) -> Result<PrivilegedResponse, PrivilegedClientError> {
        if !self.socket.exists() {
            return Err(PrivilegedClientError::MissingSocket(self.socket.clone()));
        }
        let mut stream = UnixStream::connect(&self.socket)?;
        if let Some(deadline) = deadline {
            stream.set_read_timeout(Some(deadline))?;
            stream.set_write_timeout(Some(deadline))?;
        }
        write_request(&mut stream, &operation)?;
        stream.flush()?;
        Ok(read_response(&mut stream)?)
    }
}

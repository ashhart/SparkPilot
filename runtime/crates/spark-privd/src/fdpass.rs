//! Pass terminal master descriptors with frame headers over the authenticated Unix socket; see docs/development/privileged-boundaries.md.

use std::io;
use std::mem;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;

/// Align storage for exactly one SCM_RIGHTS control message on each supported platform.
const CMSG_BUFFER_BYTES: usize = 64;

#[repr(C)]
union CmsgBuffer {
    bytes: [u8; CMSG_BUFFER_BYTES],
    _align: libc::cmsghdr,
}

/// Send `payload` and, optionally, one descriptor with it.
pub fn send_with_fd(stream: &UnixStream, payload: &[u8], fd: Option<RawFd>) -> io::Result<()> {
    let mut sent = 0usize;
    let mut pending_fd = fd;
    while sent < payload.len() {
        let mut iov = libc::iovec {
            iov_base: payload[sent..].as_ptr() as *mut libc::c_void,
            iov_len: payload.len() - sent,
        };
        let mut message: libc::msghdr = unsafe { mem::zeroed() };
        message.msg_iov = &mut iov;
        message.msg_iovlen = 1 as _;

        let mut control = CmsgBuffer {
            bytes: [0u8; CMSG_BUFFER_BYTES],
        };
        if let Some(fd) = pending_fd {
            let space = unsafe { libc::CMSG_SPACE(mem::size_of::<libc::c_int>() as u32) } as usize;
            debug_assert!(space <= CMSG_BUFFER_BYTES);
            message.msg_control = unsafe { control.bytes.as_mut_ptr() } as *mut libc::c_void;
            message.msg_controllen = space as _;
            unsafe {
                let header = libc::CMSG_FIRSTHDR(&message);
                (*header).cmsg_level = libc::SOL_SOCKET;
                (*header).cmsg_type = libc::SCM_RIGHTS;
                (*header).cmsg_len = libc::CMSG_LEN(mem::size_of::<libc::c_int>() as u32) as _;
                std::ptr::copy_nonoverlapping(
                    &fd as *const libc::c_int as *const u8,
                    libc::CMSG_DATA(header),
                    mem::size_of::<libc::c_int>(),
                );
            }
        }

        let written = unsafe { libc::sendmsg(stream.as_raw_fd(), &message, 0) };
        if written < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        // Send the descriptor only with the first delivered byte, even when the payload requires retries.
        pending_fd = None;
        sent += written as usize;
    }
    Ok(())
}

/// Read exactly `buffer.len()` bytes, returning any descriptor that arrived.
pub fn recv_exact_with_fd(stream: &UnixStream, buffer: &mut [u8]) -> io::Result<Option<OwnedFd>> {
    let mut received = 0usize;
    let mut descriptor = None;
    while received < buffer.len() {
        let mut iov = libc::iovec {
            iov_base: buffer[received..].as_mut_ptr() as *mut libc::c_void,
            iov_len: buffer.len() - received,
        };
        let mut message: libc::msghdr = unsafe { mem::zeroed() };
        message.msg_iov = &mut iov;
        message.msg_iovlen = 1 as _;
        let mut control = CmsgBuffer {
            bytes: [0u8; CMSG_BUFFER_BYTES],
        };
        let space = unsafe { libc::CMSG_SPACE(mem::size_of::<libc::c_int>() as u32) } as usize;
        message.msg_control = unsafe { control.bytes.as_mut_ptr() } as *mut libc::c_void;
        message.msg_controllen = space as _;

        let read = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut message, 0) };
        if read < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "privileged peer closed the connection",
            ));
        }

        unsafe {
            let mut header = libc::CMSG_FIRSTHDR(&message);
            while !header.is_null() {
                if (*header).cmsg_level == libc::SOL_SOCKET
                    && (*header).cmsg_type == libc::SCM_RIGHTS
                {
                    let mut raw: libc::c_int = -1;
                    std::ptr::copy_nonoverlapping(
                        libc::CMSG_DATA(header),
                        &mut raw as *mut libc::c_int as *mut u8,
                        mem::size_of::<libc::c_int>(),
                    );
                    if raw >= 0 {
                        if descriptor.is_some() {
                            // Never leak an unexpected second descriptor.
                            libc::close(raw);
                        } else {
                            descriptor = Some(OwnedFd::from_raw_fd(raw));
                        }
                    }
                }
                header = libc::CMSG_NXTHDR(&message, header);
            }
        }
        received += read as usize;
    }
    Ok(descriptor)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    #[test]
    fn a_descriptor_crosses_the_socket_with_its_frame() {
        let (server, client) = UnixStream::pair().unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"beyond the socket").unwrap();
        let opened = std::fs::File::open(file.path()).unwrap();

        send_with_fd(&server, &[1, 2, 3, 4], Some(opened.as_raw_fd())).unwrap();

        let mut header = [0u8; 4];
        let received = recv_exact_with_fd(&client, &mut header).unwrap();
        assert_eq!(header, [1, 2, 3, 4]);
        let received = received.expect("descriptor arrived");
        let mut contents = String::new();
        std::fs::File::from(received)
            .read_to_string(&mut contents)
            .unwrap();
        assert_eq!(contents, "beyond the socket");
    }

    #[test]
    fn a_frame_without_a_descriptor_reports_none() {
        let (server, client) = UnixStream::pair().unwrap();
        send_with_fd(&server, b"payload!", None).unwrap();
        let mut buffer = [0u8; 8];
        assert!(recv_exact_with_fd(&client, &mut buffer).unwrap().is_none());
        assert_eq!(&buffer, b"payload!");
    }

    #[test]
    fn a_closed_peer_is_an_error_not_a_silent_short_read() {
        let (server, client) = UnixStream::pair().unwrap();
        drop(server);
        let mut buffer = [0u8; 4];
        let error = recv_exact_with_fd(&client, &mut buffer).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }
}

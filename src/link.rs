//! The UDP link to the BeamNG mod, on 127.0.0.1. Plain-text packets; see the mod for the protocol.

use std::io::ErrorKind;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};

pub const PORT: u16 = 47731;

pub struct Link {
    socket: Option<UdpSocket>,
    destination: SocketAddr,
}

impl Link {
    pub fn new(port: u16) -> Link {
        let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
            .and_then(|s| s.set_nonblocking(true).map(|_| s))
            .map_err(|e| eprintln!("GyroSteer: can't open a UDP socket: {e}"))
            .ok();
        Link { socket, destination: SocketAddr::from((Ipv4Addr::LOCALHOST, port)) }
    }

    pub fn send(&self, text: &str) {
        if let Some(s) = &self.socket {
            // Fails harmlessly while the game isn't listening.
            let _ = s.send_to(text.as_bytes(), self.destination);
        }
    }

    /// Every reply waiting, oldest first.
    pub fn receive(&self) -> Vec<String> {
        let mut replies = Vec::new();
        let Some(s) = &self.socket else { return replies };
        let mut buffer = [0u8; 512];
        // Bounded: on Windows each packet sent while the game wasn't listening comes back as a "connection reset"
        // error, which has to be read past.
        for _ in 0..256 {
            match s.recv_from(&mut buffer) {
                Ok((n, _)) => replies.push(String::from_utf8_lossy(&buffer[..n]).into_owned()),
                Err(e) if e.kind() == ErrorKind::WouldBlock => break,
                Err(_) => continue,
            }
        }
        replies
    }
}

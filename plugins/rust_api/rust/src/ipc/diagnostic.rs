//! Closed-vocabulary metadata: never format errors, addresses, or frame contents.
use std::io;

#[derive(Clone, Copy)]
pub struct DisconnectDiagnostic {
    pub source: u8,
    pub reason: u8,
    pub os_code: Option<i32>,
}

impl DisconnectDiagnostic {
    pub fn io(source: u8, error: &io::Error) -> Self {
        let reason = match error.kind() {
            io::ErrorKind::UnexpectedEof => 1,
            io::ErrorKind::ConnectionReset => 2,
            io::ErrorKind::BrokenPipe => 3,
            io::ErrorKind::InvalidData => 4,
            io::ErrorKind::WriteZero => 5,
            io::ErrorKind::TimedOut => 6,
            io::ErrorKind::Interrupted => 7,
            _ => 8,
        };
        Self {
            source,
            reason,
            os_code: error.raw_os_error(),
        }
    }

    pub fn local(source: u8, reason: u8) -> Self {
        Self {
            source,
            reason,
            os_code: None,
        }
    }

    pub fn encode(self, last_frame_age_ms: u64) -> Vec<u8> {
        let mut payload = vec![
            1,
            self.source,
            self.reason,
            u8::from(self.os_code.is_some()),
        ];
        payload.extend_from_slice(&self.os_code.unwrap_or_default().to_le_bytes());
        payload.extend_from_slice(&last_frame_age_ms.to_le_bytes());
        payload
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arbitrary_error_text_cannot_enter_diagnostic() {
        let error = io::Error::new(io::ErrorKind::Other, "secret://user:password@private/path");
        let bytes = DisconnectDiagnostic::io(1, &error).encode(42);
        assert_eq!(bytes.len(), 16);
        assert_eq!(&bytes[..8], &[1, 1, 8, 0, 0, 0, 0, 0]);
        assert_eq!(u64::from_le_bytes(bytes[8..].try_into().unwrap()), 42);
    }
}

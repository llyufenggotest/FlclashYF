//! Runs the production IPC server/frame/queue/platform on isolated pipes.
extern crate self as flutter_rust_bridge;
pub mod for_generated { pub struct SseCodec; }
pub mod frb_generated {
    pub struct StreamSink<T, C> { pub sender: std::sync::mpsc::Sender<T>, pub codec: std::marker::PhantomData<C> }
    impl<T, C> StreamSink<T, C> { pub fn add(&self, value: T) -> Result<(), ()> { self.sender.send(value).map_err(|_| ()) } }
}
pub mod ipc {
    #[path = "../../../rust/src/ipc/diagnostic.rs"] pub mod diagnostic;
    #[path = "../../../rust/src/ipc/frame.rs"] pub mod frame;
    #[path = "../../../rust/src/ipc/platform.rs"] pub mod platform;
    #[path = "../../../rust/src/ipc/queue.rs"] pub mod queue;
    #[path = "../../../rust/src/ipc/server.rs"] pub mod server;
}
#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use interprocess::local_socket::{prelude::*, GenericFilePath, Stream};
    use std::{io::Write, sync::{mpsc, Mutex}, time::{Duration, Instant}, thread};
    static SERIAL: Mutex<()> = Mutex::new(());
    fn start() -> (mpsc::Receiver<Vec<u8>>, Stream) {
        let name = format!(r"\\.\pipe\FlClashRound2_{}_{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
        let (tx, rx) = mpsc::channel();
        ipc::server::restart_server(name.clone(), frb_generated::StreamSink { sender: tx, codec: std::marker::PhantomData }).unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), [0]);
        let peer = Stream::connect(name.to_fs_name::<GenericFilePath>().unwrap()).unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap()[0], 1);
        (rx, peer)
    }
    #[test]
    fn peer_close_emits_typed_diagnostic_without_payload_or_raw_error() {
        let _guard = SERIAL.lock().unwrap();
        let (rx, peer) = start();
        drop(peer);
        let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        ipc::server::stop_server().unwrap();
        assert_eq!(event[0], 2);
        assert_eq!(event.len(), 17, "first disconnect must carry version/source/reason/OS-code/last-frame age");
        assert_eq!(event[1], 1);
        assert_eq!(event[2], 1); // reader
        assert!(event[3] == 1 || event[3] == 2 || event[3] == 3); // EOF/reset/broken-pipe
        println!("peer_close source={} reason={} os_present={} os_code={} age_ms={}", event[2], event[3], event[4], i32::from_le_bytes(event[5..9].try_into().unwrap()), u64::from_le_bytes(event[9..17].try_into().unwrap()));
    }
    #[test]
    fn production_server_log_rpc_pressure_then_idle_over_original_window() {
        let _guard = SERIAL.lock().unwrap();
        let (rx, mut peer) = start();
        let mut payload = vec![b'L'; 32 * 256];
        for batch in 0..256_u32 {
            payload[..4].copy_from_slice(&batch.to_le_bytes());
            ipc::frame::write_frame(&mut peer, &payload, &|| true).unwrap();
            let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
            assert_eq!(event[0], 3);
            assert_eq!(&event[1..], payload);
            ipc::server::send_message(batch.to_le_bytes().to_vec()).unwrap();
            let mut frame_reader = ipc::frame::FrameReader::default();
            assert_eq!(frame_reader.poll(&mut peer).unwrap().unwrap(), batch.to_le_bytes());
        }
        let idle = Duration::from_secs(std::env::var("FLCLASH_IPC_IDLE_SECONDS").unwrap_or_else(|_| "240".into()).parse().unwrap());
        let started = Instant::now();
        assert!(matches!(rx.recv_timeout(idle), Err(mpsc::RecvTimeoutError::Timeout)));
        ipc::frame::write_frame(&mut peer, b"RPC_AFTER_IDLE", &|| true).unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), [vec![3], b"RPC_AFTER_IDLE".to_vec()].concat());
        println!("production_pipe pressure_batches=256 log_entries=8192 idle_ms={} resumed=true", started.elapsed().as_millis());
        drop(peer);
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap()[0], 2);
        ipc::server::stop_server().unwrap();
    }
    #[test]
    fn invalid_frame_records_reader_reason_without_echoing_data() {
        let _guard = SERIAL.lock().unwrap();
        let (rx, mut peer) = start();
        peer.write_all(&(ipc::frame::MAX_FRAME_SIZE as u32 + 1).to_le_bytes()).unwrap();
        let event = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(&event[..5], &[2, 1, 1, 4, 0]);
        assert_eq!(event.len(), 17);
        ipc::server::stop_server().unwrap();
        drop(peer);
    }
    #[test]
    fn partial_frame_peer_close_is_not_silently_pending() {
        let _guard = SERIAL.lock().unwrap();
        let (rx, mut peer) = start();
        peer.write_all(&100_u32.to_le_bytes()).unwrap();
        peer.write_all(b"partial").unwrap();
        thread::sleep(Duration::from_millis(50));
        drop(peer);
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap()[0], 2);
        ipc::server::stop_server().unwrap();
    }
}

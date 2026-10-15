use super::diagnostic::DisconnectDiagnostic;
use super::frame::{
    self, FrameReader, IO_POLL_INTERVAL, TYPE_CONNECTED, TYPE_DATA, TYPE_DISCONNECTED, TYPE_ERROR,
    TYPE_READY,
};
use super::platform;
use super::queue::{enqueue_message, MessageSender, MAX_PENDING_MESSAGES, SEND_QUEUE_TIMEOUT};
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::for_generated::SseCodec;
use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{GenericFilePath, ListenerNonblockingMode, ListenerOptions};
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

macro_rules! ipc_debug {
    ($($arg:tt)*) => {
        if cfg!(debug_assertions) {
            eprintln!($($arg)*);
        }
    };
}

const ACCEPT_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(50);

static RUNNING: AtomicBool = AtomicBool::new(false);
static LIFECYCLE: Mutex<()> = Mutex::new(());

struct ServerState {
    sender: Option<MessageSender>,
    handle: Option<thread::JoinHandle<()>>,
}

static STATE: Mutex<ServerState> = Mutex::new(ServerState {
    sender: None,
    handle: None,
});

fn server_active() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

fn stop_server_thread() -> Result<(), String> {
    RUNNING.store(false, Ordering::SeqCst);
    let handle = {
        let mut state = STATE.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
        state.sender = None;
        state.handle.take()
    };
    if let Some(handle) = handle {
        handle
            .join()
            .map_err(|_| "IPC server thread panicked".to_owned())?;
    }
    Ok(())
}

pub fn restart_server(name: String, sink: StreamSink<Vec<u8>, SseCodec>) -> Result<(), String> {
    let _lifecycle = LIFECYCLE
        .lock()
        .map_err(|e| format!("Lifecycle lock poisoned: {e}"))?;

    stop_server_thread()?;
    platform::cleanup_socket(&name).map_err(|e| format!("Failed to remove stale socket: {e}"))?;

    RUNNING.store(true, Ordering::SeqCst);
    let handle = thread::Builder::new()
        .name("ipc-server".into())
        .spawn(move || io_loop(name, sink))
        .map_err(|e| {
            RUNNING.store(false, Ordering::SeqCst);
            format!("Failed to spawn IPC server thread: {e}")
        })?;

    let mut state = STATE.lock().map_err(|e| format!("Lock poisoned: {e}"))?;
    state.handle = Some(handle);
    Ok(())
}

pub fn stop_server() -> Result<(), String> {
    let _lifecycle = LIFECYCLE
        .lock()
        .map_err(|e| format!("Lifecycle lock poisoned: {e}"))?;
    stop_server_thread()
}

pub fn send_message(data: Vec<u8>) -> Result<(), String> {
    frame::validate_frame_len(data.len()).map_err(|e| e.to_string())?;
    let sender = STATE
        .lock()
        .map_err(|e| format!("Lock poisoned: {e}"))?
        .sender
        .clone()
        .ok_or("IPC client is not connected")?;

    enqueue_message(&sender, data, SEND_QUEUE_TIMEOUT, &RUNNING)
}

fn report_error(sink: &StreamSink<Vec<u8>, SseCodec>, message: impl AsRef<str>) {
    let _ = sink.add(frame::make_frame(TYPE_ERROR, message.as_ref().as_bytes()));
}

fn finish_server(name: &str) {
    RUNNING.store(false, Ordering::SeqCst);
    if let Ok(mut state) = STATE.lock() {
        state.sender = None;
    }
    if let Err(e) = platform::cleanup_socket(name) {
        ipc_debug!("[IPC] cleanup socket failed: {e}");
    }
}

fn io_loop(name: String, sink: StreamSink<Vec<u8>, SseCodec>) {
    let fs_name = match name.clone().to_fs_name::<GenericFilePath>() {
        Ok(name) => name,
        Err(e) => {
            report_error(&sink, format!("name error: {e}"));
            finish_server(&name);
            return;
        }
    };

    let options = platform::restrict_listener_mode(ListenerOptions::new().name(fs_name));
    let listener = match options.create_sync() {
        Ok(listener) => listener,
        Err(e) => {
            report_error(&sink, format!("bind error: {e}"));
            finish_server(&name);
            return;
        }
    };

    if let Err(e) = platform::restrict_socket_to_owner(&name) {
        report_error(&sink, format!("socket permission error: {e}"));
        finish_server(&name);
        return;
    }

    if let Err(e) = listener.set_nonblocking(ListenerNonblockingMode::Accept) {
        report_error(&sink, format!("listener nonblocking error: {e}"));
        finish_server(&name);
        return;
    }

    if sink.add(frame::make_frame(TYPE_READY, &[])).is_err() {
        finish_server(&name);
        return;
    }

    while server_active() {
        let stream = match listener.accept() {
            Ok(stream) => stream,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL_INTERVAL);
                continue;
            }
            Err(e) => {
                if server_active() {
                    report_error(&sink, format!("accept error: {e}"));
                }
                break;
            }
        };

        if let Err(e) = platform::authorize_peer(&stream) {
            ipc_debug!("[IPC] rejected connection: {e}");
            continue;
        }

        if let Err(e) = stream.set_nonblocking(true) {
            report_error(&sink, format!("stream nonblocking error: {e}"));
            continue;
        }

        let connected_payload = match platform::connected_payload(&stream) {
            Ok(payload) => payload,
            Err(e) => {
                report_error(&sink, format!("peer credentials error: {e}"));
                continue;
            }
        };

        let (sender, rx, pending_bytes) = MessageSender::channel(MAX_PENDING_MESSAGES);
        match STATE.lock() {
            Ok(mut state) if server_active() => state.sender = Some(sender),
            Ok(_) => break,
            Err(e) => {
                report_error(&sink, format!("state lock error: {e}"));
                break;
            }
        }

        if sink
            .add(frame::make_frame(TYPE_CONNECTED, &connected_payload))
            .is_err()
        {
            break;
        }

        let (mut receiver, mut sender) = stream.split();
        let connection_running = Arc::new(AtomicBool::new(true));
        // First terminal observer wins; a reader stopping after writer failure
        // must not replace the original OS code with a local cancellation.
        let disconnect = Arc::new(Mutex::new(None::<DisconnectDiagnostic>));
        let writer_disconnect = Arc::clone(&disconnect);
        let writer_running = Arc::clone(&connection_running);
        let writer = thread::spawn(move || {
            let mut error = None;
            let is_running = || writer_running.load(Ordering::SeqCst) && server_active();
            while is_running() {
                match rx.recv_timeout(IO_POLL_INTERVAL) {
                    Ok(data) => {
                        pending_bytes.fetch_sub(data.len(), Ordering::SeqCst);
                        if let Err(e) = frame::write_frame(&mut sender, &data, &is_running) {
                            if is_running() {
                                writer_disconnect
                                    .lock()
                                    .unwrap_or_else(|p| p.into_inner())
                                    .get_or_insert(DisconnectDiagnostic::io(2, &e));
                                if !frame::is_expected_disconnect_error(&e) {
                                    error = Some("write_io_failure".to_owned());
                                }
                            }
                            break;
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        writer_disconnect
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .get_or_insert(DisconnectDiagnostic::local(2, 10));
                        break;
                    }
                }
            }
            writer_running.store(false, Ordering::SeqCst);
            error
        });

        let mut last_frame = Instant::now();
        let mut reader_failed = false;
        let mut frame_reader = FrameReader::default();
        while connection_running.load(Ordering::SeqCst) && server_active() {
            #[cfg(windows)]
            let poll_result = frame_reader.poll(&mut platform::PipeReader {
                receiver: &mut receiver,
            });
            #[cfg(not(windows))]
            let poll_result = frame_reader.poll(&mut receiver);

            match poll_result {
                Ok(Some(data)) => {
                    last_frame = Instant::now();
                    if sink.add(frame::make_frame(TYPE_DATA, &data)).is_err() {
                        disconnect
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .get_or_insert(DisconnectDiagnostic::local(3, 9));
                        break;
                    }
                }
                Ok(None) => thread::sleep(IO_POLL_INTERVAL),
                Err(e) => {
                    disconnect
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .get_or_insert(DisconnectDiagnostic::io(1, &e));
                    reader_failed = !frame::is_expected_disconnect_error(&e);
                    // The diagnostic is emitted before a generic error so Dart
                    // preserves the first disconnect, even for unusual OS errors.
                    break;
                }
            }
        }

        connection_running.store(false, Ordering::SeqCst);
        if let Ok(mut state) = STATE.lock() {
            state.sender = None;
        }
        let writer_error = match writer.join() {
            Ok(error) => error,
            Err(_) => {
                disconnect
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .get_or_insert(DisconnectDiagnostic::local(2, 11));
                Some("writer_panicked".to_owned())
            }
        };
        let diagnostic = disconnect
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .unwrap_or(DisconnectDiagnostic::local(4, 12));
        let age = last_frame.elapsed().as_millis().min(u64::MAX as u128) as u64;
        if server_active() {
            if sink
                .add(frame::make_frame(
                    TYPE_DISCONNECTED,
                    &diagnostic.encode(age),
                ))
                .is_err()
            {
                break;
            }
            if reader_failed {
                report_error(&sink, "read_io_failure".to_owned());
            }
            if let Some(message) = writer_error {
                report_error(&sink, message);
            }
        }
    }

    finish_server(&name);
}

# Windows IPC production harness

This standalone crate imports the production server/frame/queue/platform/diagnostic source files. Only the Flutter Rust Bridge `StreamSink` adapter is replaced by an mpsc channel; no App, service, system proxy, network node or TUN is started.

Use Rust with the Windows MSVC target, a real MSVC linker and Windows SDK import libraries. Run:

```
cargo test --manifest-path plugins/rust_api/ipc_harness/Cargo.toml -- --nocapture
```

Default idle is 240 seconds (greater than the observed 228-second configuration-to-disconnect interval). `FLCLASH_IPC_IDLE_SECONDS` may shorten local developer runs, but short runs are not idle acceptance evidence. Test pipes use a unique PID/time namespace unrelated to application pipes.

Binary disconnect payload (16 bytes, after event type 0x02): version u8=1, source u8, reason u8, OS-code-present u8, OS code i32 LE, last complete received frame age u64 LE milliseconds. Source/reason values are encoded and rendered with closed vocabularies; no error strings or frame contents are included. Legacy empty disconnect payloads remain accepted by Dart as unknown.

The harness exercises actual Windows named pipes and the production Rust bridge loops. It is not a packaged Flutter/FFI or real node test. Windows named pipes do not expose TCP-style `shutdown(SHUT_WR)`; tests cover full peer close and close during partial frames rather than claim a nonexistent native half-close API.

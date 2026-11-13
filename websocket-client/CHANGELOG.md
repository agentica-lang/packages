# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-11-13

Needs Agentica 0.31.0.

### Changed

- **Breaking:** needs Agentica 0.31.0, and `agentica = "0.31.0"` in the manifest says so: the `tls` of `Options` and `Client` is `Optional[TLS.Context]` (the new name of `TlsContext`), and the sources use `private` instead of `export` and the `Error` record of a failed Result (`e.message`). The public names are the same. CI tests with Agentica 0.31.0.

## [0.3.0-alpha.1] - 2026-11-12

Needs Agentica 0.31.0-alpha.1.

### Changed

- **Breaking:** needs Agentica 0.31.0-alpha.1: the headers of `Options`, `Client` and `Refused` are `List[HTTP.Header]` (`import HTTP from "std/http"`), the name of the header type in 0.31. CI tests with Agentica 0.31.0-alpha.1.

## [0.2.0] - 2026-11-12

### Added

- `WebSocket.handshake`: like `connect`, but a server that does not upgrade (a 403, a 426) gives `Refused(status, headers, body)` instead of an `error`, so a program can read why.
- `Client` gained `status` and `headers` (with defaults, so a `Client(...)` that a program builds still works): the answer of the 101 handshake, with the header names as the server wrote them.
- `connect` still stops at the head of a refusing answer; only `handshake` reads its body (at most 64 KiB). A status outside 200 to 599 other than 101 is an `error` for both.

## [0.1.0] - 2026-11-12

Needs Agentica 0.30.0 or later.

### Added

- `WebSocket.connect`: a WebSocket client (RFC 6455) for `ws://` and `wss://` over `std` TCP and TLS, with the upgrade handshake, the `Sec-WebSocket-Accept` check, subprotocols and extra headers.
- `send_text`, `send_binary`, `send_ping`, `send_pong` and `close`: every frame is masked; the close handshake has a code and a reason.
- `receive`: whole text and binary messages (fragments joined), an automatic pong for a ping, and the answer to a close frame.
- A message size limit, a read timeout, and protocol errors (a masked server frame, reserved bits, a length not in its shortest form, bad control frames, bad UTF-8) as `error` results after the close frame that RFC 6455 asks for.
- Every timeout is from 1 ms to one day (`MAX_TIMEOUT_MS`), so a huge value cannot overflow a deadline; the read, the handshake and the close wait each have one deadline, not one per read.

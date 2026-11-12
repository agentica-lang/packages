# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-12

Needs Agentica 0.30.0 or later.

### Added

- `WebSocket.connect`: a WebSocket client (RFC 6455) for `ws://` and `wss://` over `std` TCP and TLS, with the upgrade handshake, the `Sec-WebSocket-Accept` check, subprotocols and extra headers.
- `send_text`, `send_binary`, `send_ping`, `send_pong` and `close`: every frame is masked; the close handshake has a code and a reason.
- `receive`: whole text and binary messages (fragments joined), an automatic pong for a ping, and the answer to a close frame.
- A message size limit, a read timeout, and protocol errors (a masked server frame, reserved bits, a length not in its shortest form, bad control frames, bad UTF-8) as `error` results after the close frame that RFC 6455 asks for.
- Every timeout is from 1 ms to one day (`MAX_TIMEOUT_MS`), so a huge value cannot overflow a deadline; the read, the handshake and the close wait each have one deadline, not one per read.

# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.31.0-alpha.1 and Bond 0.12.0-alpha.1.

### Changed

- **Breaking:** needs Agentica 0.31.0-alpha.1 and Bond 0.12.0-alpha.1 (the package is pinned by that tag): the server options are `HTTP.ServerOptions` of `std/http`, and the sources are formatted with its `agentica fmt`. CI tests with Agentica 0.31.0-alpha.1.

## [0.3.1] - 2026-11-12

Needs Agentica 0.30.0 or later and Bond 0.11.0.

### Changed

- Needs Bond 0.11.0 (the package is pinned by the tag), which has no chain after the `end` of a `do` block, so the sources check with the next Agentica too. Nothing else changes.

## [0.3.0] - 2026-11-11

Needs Agentica 0.30.0 or later and Bond 0.10.1.

### Changed

- The hub is an actor of `std/actor`: its receive loop and its start are the actor's, with the same behaviour and the same API (`Hub`, `Channels.start_hub`, `Channels.stop_hub`, `hub.task`).
- **Breaking:** needs Agentica 0.30.0 or later: the sources handle the new `HTTP.Message.Prepared` variant and are formatted with `agentica fmt` of 0.30.0, which uses its syntax (implicit returns, guards, one-line defs). CI tests with Agentica 0.30.0.

## [0.2.1] - 2026-11-08

Needs Bond 0.10.1 (faster static files and headers). Nothing else changes.

## [0.2.0] - 2026-11-08

Needs Agentica 0.27.0 or later and Bond 0.10.0 (the Bond package is pinned by the tag 0.10.0).

### Changed

- **Breaking:** needs Agentica 0.27.0 and Bond 0.10.0. The Turbo signing uses the `OpenSSL.KDF` and `OpenSSL.HMAC` builtins, which replace `KDF` and `HMAC` in 0.27.0, so the package no longer runs on Agentica 0.25.0. The signed names are the same as before.

## [0.1.0] - 2026-11-08

Needs Agentica 0.25.0 or later and Bond 0.9.0 (the Bond package is pinned by the tag 0.9.0).

### Added

- The `actioncable-v1-json` frames as pure functions (`src/protocol.agc`): the server frames (welcome, ping, confirm and reject, both disconnects, a message with a string or an object payload) as compact JSON, and `decode_command` for the client commands (subscribe, unsubscribe, message with its `data` parsed a second time, a blank `action` meaning `receive`).
- `Channels.start_hub`, `Channels.mount`, `Channels.handler`, `Channels.broadcast_text`, `Channels.broadcast_json`, `Channels.stats` and `Channels.stop_hub` (`channels.agc`): the cable WebSocket at a path of a Bond app, one hub task for the topics, one inbox per connection, and the Action Cable and WebSocket pings that keep a quiet client connected.
- `Channels.HubOptions` (`broadcast_wait_ms`, `beat_ms`) for `start_hub` and `Channels.MountOptions` (`connect`, `handlers`, `allowed_origins`, `inbox`, `idle_ms`, `max_message_bytes`) for `mount(app, path, hub, options)`, so a field given to the wrong one does not compile. `start_hub` and `mount` return a `Result`: an `error` for a `beat_ms` under 1, a negative wait, an `inbox` or `max_message_bytes` under 1, or an `idle_ms` that is not more than the hub's `beat_ms`.
- A connection that is closed, dropped or whose handler crashes runs `unsubscribed` for each of its subscriptions. A connection too slow for its traffic is closed by the hub, and gets a `disconnect` frame with `reconnect: true`.
- A hub that ended (`stop_hub`) or crashed tells its connections to reconnect (`disconnect` with `reconnect: true`, then close 1001) within 2 s, and a new connection is refused the same way, without a `welcome`. A hub whose inbox stays full for `broadcast_wait_ms` refuses a new connection with `reconnect: true` and a close 1013 ("the hub is busy").
- A `subscribed` that returns an `error` answers `reject_subscription` and forgets the subscription.
- Turbo: `Channels.stream_key`, `Channels.signed_stream_name` and `Channels.verified_stream_name` (`src/signing.agc`), the signed stream names in the format of Rails (`Turbo.signed_stream_verifier`), so a name that Rails signed verifies and the other way round, checked against vectors that Rails made. `Channels.turbo_streams(key, authorize)` is the handler of `<turbo-cable-stream-source>`: it streams from a verified, non-empty name that `authorize` allows, and rejects the rest.
- `Channels.disconnect(hub, identity, reconnect)`: ends every connection whose `Identity.id` is `identity`, with `{"type":"disconnect","reason":"remote","reconnect":RECONNECT}` and a close 1000, as `remote_connections.where(...).disconnect` of Rails does, so a person who loses a right that `connect` or `subscribed` checked once (a sign-out, a deactivation, a removal from a room) stops hearing the streams. With `reconnect: true` the client comes back and `connect` and `subscribed` decide again. A connection whose inbox is full is told the same, not a drop.
- `Channels.stop_hub` also ends the ticker of the hub, so a program or a test that waits for its tasks is not kept for one more beat.

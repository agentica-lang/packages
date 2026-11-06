# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.24.4 or later and Bond 0.7.0.

### Added

- The `actioncable-v1-json` frames as pure functions (`src/protocol.agc`): the server frames (welcome, ping, confirm and reject, both disconnects, a message with a string or an object payload) as compact JSON, and `decode_command` for the client commands (subscribe, unsubscribe, message with its `data` parsed a second time, a blank `action` meaning `receive`).
- `Channels.start_hub`, `Channels.mount`, `Channels.handler`, `Channels.broadcast_text`, `Channels.broadcast_json`, `Channels.stats` and `Channels.stop_hub` (`channels.agc`): the cable WebSocket at a path of a Bond app, one hub task for the topics, one inbox per connection, and the Action Cable and WebSocket pings that keep a quiet client connected.
- A connection that is closed, dropped or whose handler crashes runs `unsubscribed` for each of its subscriptions. A connection too slow for its traffic is closed by the hub, and gets a `disconnect` frame with `reconnect: true`.

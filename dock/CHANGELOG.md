# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Dock.start`, `Dock.stop` and `Dock.wait`: an accept loop with a task per client, whose socket is closed when the
  handler returns, crashes or is cancelled; `Dock.recv`, `Dock.send` and `Dock.close` for the handler.
- `Dock.send` is queued: it returns at once from any task, keeps the order of the calls, and drops a client whose
  queued bytes pass `max_outbox_bytes` (8 MiB by default, 65 to
  68,157,310). `Dock.close` closes after the queue is written.
- `max_connections`: a connection over the limit is accepted and closed at once, and counted. `Dock.stats(server)`
  reads open, accepted, refused, dropped and crashed.
- `on_close` (`Dock.on_close(config) do |conn| ... end`) runs for each connection that ended: returned, crashed or
  cancelled.
- `grace_ms`: `Dock.stop` lets the queued bytes of the clients be written before it closes them.
- `Dock.watch(server, task)`: the server stops when the task ends, and `wait` returns the crash.

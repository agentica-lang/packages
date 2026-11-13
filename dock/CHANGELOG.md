# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.0] - 2026-11-13

Needs Agentica 0.31.0.

### Changed

- **Breaking:** needs Agentica 0.31.0, and `agentica = "0.31.0"` in the manifest says so: the sources use `private` instead of `export`, `TCP.Socket` and `TCP.Listener`, and the `Error` record of a failed Result (`e.message`). The public names are the same, and so are the messages of the errors; an error that comes from a builtin (a socket call) now carries a kind and a code. CI tests with Agentica 0.31.0.

## [0.3.0-alpha.1] - 2026-11-12

Needs Agentica 0.31.0-alpha.1.

### Changed

- **Breaking:** needs Agentica 0.31.0-alpha.1. CI tests with Agentica 0.31.0-alpha.1.

## [0.2.0] - 2026-11-11

Needs Agentica 0.30.0 or later.

### Changed

- **Breaking:** needs Agentica 0.30.0 or later: the sources are formatted with `agentica fmt` of 0.30.0, which uses its syntax (implicit returns, guards, one-line defs). CI tests with Agentica 0.30.0.

## [0.1.1] - 2026-11-10

### Added

- `Dock.hand_over(conn)`: the handler may return and leave the connection to another task. It then ends at `Dock.close`,
  when a `Dock.recv` sees the end of the client or fails, at the outbox cap, or at `stop`; `on_close` runs once at that
  end. The docs show the store task pattern and how an `on_close` callback retries its notice.

## [0.1.0] - 2026-11-10

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
- `grace_ms` (0 to one hour): `Dock.stop` lets the queued bytes of the clients be written before it closes them.
- `Dock.watch(server, task)`: the server stops when the task ends (also when it returns, then `wait` returns ok), and
  `wait` returns the crash.

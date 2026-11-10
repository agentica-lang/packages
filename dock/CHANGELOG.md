# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Dock.start`, `Dock.stop` and `Dock.wait`: an accept loop with a task per client, whose socket is closed when the
  handler returns, crashes or is cancelled; `Dock.recv`, `Dock.send` and `Dock.close` for the handler.
  `send` is queued in the next version, and `send_ms` goes away.

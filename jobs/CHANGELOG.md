# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.34.0.

### Added

- The contract of a jobs backend, `Jobs.Backend`: a record of functions to enqueue, fetch with a lease, ack, nack, extend, count and close, with at-least-once delivery, attempts counted at the fetch, unique keys and an all-or-nothing `enqueue_all`.
- `Jobs.enqueue`, `enqueue_all`, `fetch`, `ack`, `nack`, `extend`, `counts`, `close` and `discard`; `Jobs.json` and `Jobs.decode` for JSON payloads. A job that waits for a time has `run_at_ms`.
- `Jobs.manual_clock`, a clock that moves only when told.

# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- `jobs.enqueue`: a batch with a duplicate of a unique key emitted one event for each duplicate, with the same totals; it is now one event for each queue, with the jobs added in `count` and the duplicates in `duplicate_count`.

## [0.3.0] - 2026-11-18

Needs Agentica 0.34.1.

### Added

- Telemetry events (the `telemetry` package, pinned at `telemetry-0.1.0`): `jobs.enqueue`, `jobs.fetch`, `jobs.ack` and `jobs.nack` for the calls of every backend, and `Jobs.drain` runs each handler in the span `jobs.job` (`start`, `stop` or `error`, with `error_kind: "jobs.discard"` for a discard) and says its verdict in `jobs.job.settle`. The log lines of a drain stay. With no handler attached a call costs a table read. The names, measurements and metadata are in the new events page of the docs.

### Changed

- **Breaking:** `jobs` needs Agentica 0.34.1 (it was 0.34.0), and depends on `telemetry` at `telemetry-0.1.0`: an app that uses `jobs` and `telemetry` must pin the same tag.

## [0.2.0] - 2026-11-18

Needs Agentica 0.34.0.

### Added

- A limit of concurrent jobs per group: `NewJob.group` and `Fetch.max_per_group` (0 is no limit), and `Jobs.drain` logs the `group`.

## [0.1.0] - 2026-11-17

Needs Agentica 0.34.0.

### Added

- The contract of a jobs backend, `Jobs.Backend`: a record of functions to enqueue, fetch with a lease, ack, nack, extend, count and close, with at-least-once delivery, attempts counted at the fetch, unique keys and an all-or-nothing `enqueue_all`.
- `Jobs.Later`: a `Retry` says when the job runs again and what went wrong, and the next delivery shows it as `last_error`.
- `Jobs.enqueue`, `enqueue_all`, `fetch`, `ack`, `nack`, `extend`, `counts`, `close` and `discard`; `Jobs.json` and `Jobs.decode` for JSON payloads. A job that waits for a time has `run_at_ms`.
- `Jobs.memory`: a backend in one actor, with leases that run out, retries, scheduled jobs, unique keys held until the job is done, a fetch that waits, `max_jobs` (`jobs.full`) and `max_dead`; acked jobs are deleted and dead jobs are kept.
- `Jobs.Caps` and `Backend.caps`: `has_clock` says whether a backend follows an injected clock.
- The conformance suite, `jobs/conformance`: 27 cases that every backend must pass, run with `Conformance.run_all` on a fresh backend and a manual clock each. A backend that cannot follow an injected clock runs the time cases on the real clock.
- `Jobs.manual_clock`, a clock that moves only when told, and `Jobs.drain`, which runs the jobs of a queue in the caller for the tests of an app. It logs (`std/logger`) a job that failed and will run again as a `warning`, and a dead job as an `err`, with the queue, the id and the attempt as fields (a dead job also has its `reason`: `discarded` or `attempts_exhausted`).

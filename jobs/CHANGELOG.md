# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.34.0.

### Added

- The contract of a jobs backend, `Jobs.Backend`: a record of functions to enqueue, fetch with a lease, ack, nack, extend, count and close, with at-least-once delivery, attempts counted at the fetch, unique keys and an all-or-nothing `enqueue_all`.
- `Jobs.enqueue`, `enqueue_all`, `fetch`, `ack`, `nack`, `extend`, `counts`, `close` and `discard`; `Jobs.json` and `Jobs.decode` for JSON payloads. A job that waits for a time has `run_at_ms`.
- `Jobs.memory`: a backend in one actor, with leases that run out, retries, scheduled jobs, unique keys held until the job is done, a fetch that waits, `max_jobs` (`jobs.full`) and `max_dead`; acked jobs are deleted and dead jobs are kept.
- `Jobs.Caps` and `Backend.caps`: `has_clock` says whether a backend follows an injected clock.
- The conformance suite, `jobs/conformance`: 24 cases that every backend must pass, run with `Conformance.run_all` on a fresh backend and a manual clock each. A backend that cannot follow an injected clock runs the time cases on the real clock.
- `Jobs.manual_clock`, a clock that moves only when told, and `Jobs.drain`, which runs the jobs of a queue in the caller for the tests of an app. It logs (`std/logger`) a job that failed and will run again as a `warning`, and a dead job as an `err`, with the queue, the id and the attempt.
- `Jobs.Later`: a `Retry` says when the job runs again and what went wrong, and the next delivery shows it as `last_error`.

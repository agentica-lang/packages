# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-13

Needs Agentica 0.31.0.

### Added

- A generic pool of resources, `import Pool from "pkg/pool/pool"`: `Pool.start`, `Pool.with`, `Pool.close` with a drain, and `Pool.timeout?`. It comes from the pool of `agentica-db` (its `src/pool`, from 0.4.0; the history of that file stays there), with the same import path, names, settings, defaults and messages of the errors.
- Callers wait in line, first come, first served, up to `max_waiting` (one more is refused with `pool error: queue full (max_waiting N)`, and 0 lets nobody wait). Up to `max_overflow` more resources are made in a spike and ended after `overflow_idle_ms` of idleness, and the health tick pings the idle resources and applies `max_age_ms` and `idle_ms`.
- Each error of the pool has a kind: `pool.timeout.checkout`, `pool.timeout.lease`, `pool.full`, `pool.closed`, and `argument` for a setting out of range.
- `checkout` in the `Spec` (optional): a check of the resource in the caller before each body, so one that broke while idle is ended instead of lent.
- `lease_ms: 0` runs the body in the caller, with no limit, about three times faster than in a task of its own.

### Changed from the pool of agentica-db

For code that used `pkg/pool/pool` inside `agentica-db` (`DbPool`):

- The body runs in a task of its own only when `lease_ms` is above 0 (the default, 30000, keeps it so). A checkout costs one task instead of three, and callers that wait no longer poll.
- Cancelling a caller cancels its body, and its resource is checked in by its keeper with `TimedOut` (so it is ended and replaced) instead of the body running on for up to `lease_ms`. A caller cancelled while it waits leaves the line.
- `init`, `ping` and `terminate` run in a task of their own for each resource, not in the owner task, and `checkin` runs in the caller: a slow or crashing one no longer stalls or ends the pool, and an `init` that crashes counts as a failed `init`.
- At the end of a drain, a body that runs in its caller (`lease_ms` 0) is not cancelled: it finds its resource ended.
- `lease_ms` may be 0; a negative one is refused with `pool error: checkout_ms must be at least 1, and lease_ms 0 or more` (was `checkout_ms and lease_ms must be at least 1`).
- The fields of `Pool` other than `spec` (`jobs`, `control`, `owner`, `counts`) are private.
- A task that has used the pool counts its crash as observed, since the pool watches it.

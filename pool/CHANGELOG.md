# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- With `lease_ms` above 0, `checkout` runs in the task of the body, not in a task of its own, so a check costs no task. The caller still waits at most 5 seconds for it, and a `checkout` that refuses, crashes or hangs still ends the resource without reaching the caller, which gets the next resource at its place in line.
- A body that runs in a task of the pool does not start when the drain of a close ended while its `checkout` ran, also when the owner is still running (another resource in a slow `init`): the caller gets `pool error: closed`. The 5 seconds that a caller waits for `checkout` hold for one that waits (a sleep, a channel, I/O, a `compute def`), not for one that blocks in a plain native `def` call.
- `close` returns after the last count is written: `waiting` and `live` are 0 when it returns.

### Documented

- `checkin` runs at most once for each body that ran (the 0.1.0 entry said once): a caller cancelled with `lease_ms` 0 after it told the pool it is checking in, and before its `checkin` starts, has its resource ended with no `checkin`.
- A `terminate` that never returns holds its place and the pool does not replace the resource, so each one makes the pool one resource smaller; `terminate` runs in the keeper, which owns the handles, so it cannot be bounded with a task.

## [0.1.0] - 2026-11-13

Needs Agentica 0.31.0.

### Added

- A generic pool of resources, `import Pool from "pkg/pool/pool"`: `Pool.start`, `Pool.with`, `Pool.close` with a drain, and `Pool.timeout?`. It comes from the pool of `agentica-db` (its `src/pool`, from 0.4.0; the history of that file stays there), with the same import path, names, settings, defaults and messages of the errors.
- Callers wait in line, first come, first served, up to `max_waiting` (one more is refused with `pool error: queue full (max_waiting N)`, and 0 lets nobody wait for a busy resource). Up to `max_overflow` more resources are made in a spike and ended after `overflow_idle_ms` of idleness, and the health tick pings the resources idle for `health_ms` and applies `max_age_ms` and `idle_ms`.
- Each error of the pool has a kind: `pool.timeout.checkout`, `pool.timeout.lease`, `pool.full`, `pool.closed`, and `argument` for a setting out of range.
- `checkout` in the `Spec` (optional): a check of the resource before each body, so one that broke while idle is ended instead of lent.
- `lease_ms: 0` runs the body in the caller, with no limit, about three times faster than in a task of its own.

### Changed from the pool of agentica-db

For code that used `pkg/pool/pool` inside `agentica-db` (`DbPool`):

- The body runs in a task of its own only when `lease_ms` is above 0 (the default, 30000, keeps it so). A checkout costs one task instead of three, and callers that wait no longer poll.
- Cancelling a caller cancels its body, and its resource is checked in by its keeper with `TimedOut` (so it is ended and replaced) instead of the body running on for up to `lease_ms`. A caller cancelled while it waits leaves the line.
- `init`, `ping` and `terminate` run in a task of their own for each resource, not in the owner task, so a slow or crashing one no longer stalls or ends the pool, and an `init` that crashes counts as a failed `init`. `checkin` still runs in a task of its own for at most 5 seconds after the caller has its result (`lease_ms` 0: in the caller).
- `checkin` runs once for each body that ran: not for a caller that ended before its body started, nor again for one that ended during its `checkin`.
- At the end of a drain, a body that runs in its caller (`lease_ms` 0) is not cancelled: it finds its resource ended. The keepers have 6 seconds after the drain (was 2), so `terminate` runs after a ping or `checkin` in flight.
- `lease_ms` may be 0; a negative one is refused with `pool error: checkout_ms must be at least 1, and lease_ms 0 or more` (was `checkout_ms and lease_ms must be at least 1`).
- `Pool.jobs` and `Pool.control` are gone. `Pool.counts` keeps `waiting` and `live`, now kept by the owner task, and `closed`.
- A task that has used the pool counts its crash as observed, since the pool watches it ([agentica-lang/agentica#1522](https://github.com/agentica-lang/agentica/issues/1522)).

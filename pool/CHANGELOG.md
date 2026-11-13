# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.31.0.

### Added

- The generic pool of `agentica-db` (its `src/pool`, which shipped there from 0.4.0), now a package of its own: `Pool.start`, `Pool.with`, `Pool.close` with a drain, and `Pool.timeout?`. Import it as `import Pool from "pkg/pool/pool"`, the same path as before. The public names and signatures are the same, and so are the messages of the errors; the history of the file stays in `agentica-lang/agentica-db`.
- Callers wait in line, first come, first served. The resource of a body that crashes or runs past `lease_ms` is checked in or ended and replaced, up to `max_overflow` more resources are made in a spike (ended after `overflow_idle_ms` of idleness), and idle resources are pinged and replaced by `max_age_ms` and `idle_ms`.
- `max_waiting` limits the callers in line: one more is refused with `pool error: queue full (max_waiting N)`, and 0 lets nobody wait.
- Features for the hard inputs: a caller refused with `max_waiting` 0, many callers at once (no resource in two bodies, none lost), a burst over `size` and `max_waiting`, a resource that `checkin` refuses after a clean body, the close with callers in line, and a body cut off by the close.

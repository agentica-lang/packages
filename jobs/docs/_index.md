---
title: jobs
description: Produce and consume jobs with a swappable backend. A contract with leases, retries and dead jobs.
---

`jobs` is for work that runs later, or somewhere else: send an email, post a webhook, delete a room. A producer adds a job to a queue; a consumer fetches it, runs it and says it is done. The backend that keeps the queue is a value you pass around, so an app can use one backend in its tests and another in production, with the same code.

This part of the package is the contract that every backend fills. The memory backend, the conformance suite and the helpers for tests come in the next parts.

Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add jobs https://github.com/agentica-lang/packages --tag jobs-0.1.0 --subdir jobs
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
jobs = { git = "https://github.com/agentica-lang/packages", tag = "jobs-0.1.0", subdir = "jobs" }
```

A job is a payload (bytes) in a named queue. `Jobs.json` makes one from a value, and `Jobs.decode` reads it back with a codec. A consumer calls `fetch`, which leases the jobs: nobody else gets them until the lease runs out. `ack` says the job is done and removes it. If the consumer crashes or hangs, the lease runs out and the job comes back, so a job that was enqueued runs until it is acked or dead. That is at-least-once delivery: a handler can run twice for one job, so it must be idempotent.

## API

```signature
Jobs.enqueue(backend: Backend, job: NewJob) -> Result[Enqueued]
Jobs.enqueue_all(backend: Backend, jobs: List[NewJob]) -> Result[List[Enqueued]]
Jobs.json(queue: String, value: T) -> NewJob
Jobs.decode(job: Job, codec: Codec[T]) -> Result[T]
Jobs.fetch(backend: Backend, options: Fetch) -> Result[List[Lease]]
Jobs.ack(backend: Backend, lease: Lease) -> Result[Void]
Jobs.nack(backend: Backend, lease: Lease, how: Nack) -> Result[Void]
Jobs.extend(backend: Backend, lease: Lease, ms: Int) -> Result[Lease]
Jobs.counts(backend: Backend, queue: String) -> Result[Counts]
Jobs.close(backend: Backend, drain_ms: Int) -> Void
Jobs.discard(reason: String) -> Result[Void]
Jobs.manual_clock() -> Clock
```

- `NewJob` has the `queue`, the `payload`, `max_attempts` (5), `run_at_ms` (0 is now; a later Unix time schedules the job), a `unique_key` and a `meta` map. To schedule a job there is no second function: set `run_at_ms`.
- `Fetch` has the `queue`, `max` jobs (1), `lease_ms` (30 s) and `wait_ms` (0: do not wait). No job in time gives `ok([])`.
- `Nack` says how a job goes back: `Retry(Later(at_ms: ..., error: ...))` runs it again at that time, and the handler of the next delivery reads the `error` as the `last_error` of its job, `Release` gives it back now without counting the attempt, and `Dead(reason)` keeps it as dead and never runs it again.
- `Counts` has the `ready`, `scheduled`, `leased` and `dead` jobs of a queue.

[The contract](contract.md) says what every backend guarantees.

## Errors

Every call that can fail gives a `Result`. A failure that a caller may branch on has a kind: `jobs.closed` (the backend was closed), `jobs.full` (a backend holds as many live jobs as it allows), `jobs.lease_lost` (the lease ran out or was replaced by a newer delivery), `jobs.discard` (what a handler returns to say that its job is dead), `jobs.timeout` (a backend did not answer in time), and the builtin `argument` for a bad value. Test them with `e.is_a?("jobs.lease_lost")`, never with the message.

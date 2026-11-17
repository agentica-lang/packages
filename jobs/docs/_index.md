---
title: jobs
description: Produce and consume jobs with a swappable backend. A contract with leases, retries and dead jobs, an in-memory backend, a conformance suite that every backend must pass, and a manual clock for tests.
---

`jobs` is for work that runs later, or somewhere else: send an email, post a webhook, delete a room. A producer adds a job to a queue; a consumer fetches it, runs it and says it is done. The backend that keeps the queue is a value you pass around, so an app can use the memory backend in its tests and a database in production, with the same code.

This is the first release: the contract, the memory backend, the conformance suite and a helper for tests. The pipeline that runs consumers for you comes next.

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

```agentica
import Jobs from "pkg/jobs/jobs"

struct Mail
  to: String
end

def main() -> Void
  backend = Jobs.memory().unwrap!
  _ = Jobs.enqueue(backend, Jobs.json("mail", Mail(to: "ana@example.com"))).unwrap!
  leases = Jobs.fetch(backend, Jobs.Fetch(queue: "mail")).unwrap!
  mail = Jobs.decode(leases[0].job, Mail.codec).unwrap!
  puts("send a mail to #{mail.to}")
  _ = Jobs.ack(backend, leases[0])
  Jobs.close(backend, 1000)
end
```

```output
send a mail to ana@example.com
```

`Jobs.memory` starts an actor that is a child of the task that calls it, so make the backend in `main`. Its jobs die with the process: use it for tests and for work that may be lost.

## API

```signature
Jobs.memory(options: MemoryOptions = MemoryOptions()) -> Result[Backend]
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
Jobs.drain(backend: Backend, options: Drain, handle: Fn[Job, Result[Void]]) -> Result[Drained]
Jobs.manual_clock() -> Clock
```

- `NewJob` has the `queue`, the `payload`, `max_attempts` (5), `run_at_ms` (0 is now; a later Unix time schedules the job), a `unique_key` and a `meta` map. To schedule a job there is no second function: set `run_at_ms`.
- `Fetch` has the `queue`, `max` jobs (1), `lease_ms` (30 s) and `wait_ms` (0: do not wait). No job in time gives `ok([])`.
- `Nack` says how a job goes back: `Retry(Later(at_ms: ..., error: ...))` runs it again at that time, and the handler of the next delivery reads the `error` as the `last_error` of its job, `Release` gives it back now without counting the attempt, and `Dead(reason)` keeps it as dead and never runs it again.
- `Counts` has the `ready`, `scheduled`, `leased` and `dead` jobs of a queue.

The pages: [the contract](contract.md) says what every backend guarantees and how to write one, and [testing](testing.md) is for the tests of an app.

## Errors

Every call that can fail gives a `Result`. A failure that a caller may branch on has a kind: `jobs.closed` (the backend was closed), `jobs.full` (the memory backend holds `max_jobs` live jobs), `jobs.lease_lost` (the lease ran out or was replaced by a newer delivery), `jobs.discard` (what a handler returns to say that its job is dead), `jobs.timeout` (a backend did not answer in time), and the builtin `argument` for a bad value. Test them with `e.is_a?("jobs.lease_lost")`, never with the message.

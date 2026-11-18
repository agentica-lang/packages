---
title: jobs
description: Produce and consume jobs with a swappable backend. A contract with leases, retries and dead jobs, an in-memory backend, a conformance suite that every backend must pass, and a manual clock for tests.
---

`jobs` is for work that runs later, or somewhere else: send an email, post a webhook, delete a room. A producer adds a job to a queue; a consumer fetches it, runs it and says it is done. The backend that keeps the queue is a value you pass around, so an app can use the memory backend in its tests and another backend elsewhere, with the same code.

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

## Limit the jobs of a group

Some work must not run all at once for one customer, bot or host: ten posts to one webhook at the same time will be refused. Give the jobs a `group`, and fetch with `max_per_group`: a fetch skips a ready job whose group already has that many live leases, and takes the next ready job, so a busy group does not hold back the others. A lease that ends (an ack, a nack of any kind, or its expiry) frees a place, and a fetch that waits is woken by it.

```agentica
import Jobs from "pkg/jobs/jobs"

def post(bot: String, text: String) -> Jobs.NewJob
  Jobs.NewJob(queue: "posts", payload: text.bytes, group: some(bot))
end

def names(leases: List[Jobs.Lease]) -> List[String]
  leases.map(->(lease) { String.from_bytes(lease.job.payload).unwrap_or("?") })
end

def main() -> Void
  backend = Jobs.memory().unwrap!
  _ = Jobs.enqueue_all(backend, [post("ana", "ana 1"), post("ana", "ana 2"), post("bo", "bo 1")]).unwrap!
  fetch = Jobs.Fetch(queue: "posts", max: 10, max_per_group: 1)
  first = Jobs.fetch(backend, fetch).unwrap!
  puts(names(first))
  puts(names(Jobs.fetch(backend, fetch).unwrap!))
  _ = Jobs.ack(backend, first[0])
  puts(names(Jobs.fetch(backend, fetch).unwrap!))
  Jobs.close(backend, 1000)
end
```

```output
["ana 1", "bo 1"]
[]
["ana 2"]
```

The limit is a field of the fetch, not a setting of the queue: it is the consumer that knows how much its work can take, a backend has no setting to store, and a database backend counts the live leases of a group with a query. The consumers of one queue should pass the same limit. If they pass different ones, each fetch counts the same live leases against its own limit, so a fetch with a higher limit takes jobs that one with a lower limit skipped. The limit of a bot and the limit of the whole queue are two limits: `max_per_group` is the first, and the number of consumers (their `max` and tasks) is the second.

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
Jobs.discard(message: String) -> Result[Void]
Jobs.drain(backend: Backend, options: Drain, handle: Fn[Job, Result[Void]]) -> Result[Drained]
Jobs.manual_clock() -> Clock
```

- `NewJob` has the `queue`, the `payload`, `max_attempts` (5), `run_at_ms` (0 is now; a later Unix time schedules the job), a `unique_key`, a `group` and a `meta` map. To schedule a job there is no second function: set `run_at_ms`.
- `Fetch` has the `queue`, `max` jobs (1), `lease_ms` (30 s) and `wait_ms` (0: do not wait) and `max_per_group` (0: no limit). No job in time gives `ok([])`.
- `Nack` says how a job goes back. `Retry(Later(at_ms: ..., error: ...))` runs it again at `at_ms`, and the next delivery shows the `error` as the `last_error` of its job. `Release` gives it back now, without counting the attempt. `Dead(error)` keeps it as dead and never runs it again.
- `Counts` has the `ready`, `scheduled`, `leased` and `dead` jobs of a queue.

The pages: [the contract](contract.md) says what every backend guarantees and how to write one, and [testing](testing.md) is for the tests of an app.

## Errors

Every call that can fail gives a `Result`. A failure that a caller may branch on has a kind: `jobs.closed` (the backend was closed), `jobs.full` (the memory backend holds `max_jobs` live jobs), `jobs.lease_lost` (the lease ran out or was replaced by a newer delivery), `jobs.discard` (what a handler returns to say that its job is dead), `jobs.timeout` (a backend did not answer in time), and the builtin `argument` for a bad value. Test them with `e.is_a?("jobs.lease_lost")`, never with the message.

## The records that the files of `jobs` share. `jobs.agc` re-exports them.

## A job to add. `run_at_ms` 0 means now; a later Unix time schedules it. A `unique_key` makes a second enqueue of the
## same key in the same queue a duplicate while the first is not finished (acked or dead).
struct NewJob
  queue: String
  payload: Bytes
  max_attempts: Int = 5
  run_at_ms: Int = 0
  unique_key: Optional[String] = none
  meta: Map[String, String] = {}
end

## A job as a backend hands it out. `id` is a String, since backends differ (a DB key, a Redis stream id). `attempt` is
## 1 on the first delivery and counts every delivery, also one whose lease expired.
struct Job
  id: String
  queue: String
  payload: Bytes
  attempt: Int
  max_attempts: Int
  run_at_ms: Int
  inserted_at_ms: Int
  unique_key: Optional[String]
  meta: Map[String, String]
  last_error: Optional[String]
end

## A job held by one consumer until `expires_at_ms`. `token` names this delivery: ack, nack and extend with the token
## of an older delivery fail with `jobs.lease_lost`.
struct Lease
  job: Job
  token: String
  expires_at_ms: Int
end

struct Enqueued
  id: String
  duplicate: Bool
end

## Up to `max` jobs of `queue`, each leased for `lease_ms`, waiting up to `wait_ms` for the first one (0 does not
## wait). No job in time gives `ok([])`.
struct Fetch
  queue: String
  max: Int = 1
  lease_ms: Int = 30_000
  wait_ms: Int = 0
end

## When a failed job runs again, and what went wrong. The handler of the next delivery reads `error` as the
## `last_error` of its job.
struct Later
  at_ms: Int
  error: Optional[String] = none
end

## How a job goes back. `Retry(later)`: run again at that time (on the last attempt the job is dead instead).
## `Release`: back now, and the attempt does not count (a stop that never started it). `Dead(error)`: never again;
## kept as dead.
enum Nack
  Retry(Later)
  Release
  Dead(String)
end

struct Counts
  ready: Int
  scheduled: Int
  leased: Int
  dead: Int
end

## The contract: a backend fills the record, and the functions of `Jobs` call it.
struct Backend
  name: String
  enqueue: Fn[List[NewJob], Result[List[Enqueued]]]
  fetch: Fn[Fetch, Result[List[Lease]]]
  ack: Fn[Lease, Result[Void]]
  nack: Fn[Lease, Nack, Result[Void]]
  extend: Fn[Lease, Int, Result[Lease]]
  counts: Fn[String, Result[Counts]]
  close: Fn[Int, Void]
end

## A clock that moves only when told: `now` reads it, `advance(ms)` moves it. Give `now` to a backend as its clock.
struct Clock
  now: Fn[Int]
  advance: Fn[Int, Void]
end

## The options of the memory backend. `max_jobs` is how many jobs may be live (ready, scheduled or leased) at once;
## past it `enqueue` fails with `jobs.full`. `max_dead` is how many dead jobs are kept; the oldest is dropped. `clock`
## gives Unix ms, and defaults to the wall clock.
struct MemoryOptions
  max_jobs: Int = 10_000
  max_dead: Int = 1_000
  clock: Optional[Fn[Int]] = none
end

## `Ready` runs the jobs whose time has come; `All` also runs the ones that wait for a time, moving the manual clock of
## the drain.
enum Due
  Ready
  All
end

## What `Jobs.drain` runs: the jobs of `queue`, at most `max_runs` of them. `Due.All` needs the `clock` that the
## backend follows. `backoff` gives the wait in ms before a failed job runs again, from its attempt (the default
## doubles from 1 s up to 1 h, with some jitter).
struct Drain
  queue: String
  due: Due = Due.Ready
  max_runs: Int = 1_000
  clock: Optional[Clock] = none
  backoff: Optional[Fn[Int, Int]] = none
end

## How many jobs a drain acked, put back to run again, and made dead.
struct Drained
  done: Int
  retried: Int
  dead: Int
end

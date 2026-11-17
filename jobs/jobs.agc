## Produce and consume jobs, with the backend swappable (the memory backend here; `jobs-db` and others fill the same
## `Backend` record). A producer calls `enqueue`; a consumer calls `fetch`, runs the job, and `ack`s it, or `nack`s it
## to run again later. A fetched job is leased: if its consumer crashes or hangs, the lease runs out and the job comes
## back, so every enqueued job runs until it is acked or dead (at least once: handlers must be idempotent).
##
## Errors have a kind: `jobs.closed`, `jobs.full`, `jobs.lease_lost`, `jobs.discard`, `jobs.timeout` (a backend did not
## answer in time), and the builtin `argument` for a bad value.
##
## `Jobs.memory` starts an actor that is a child of the task that calls it: make it in `main`.

import Inline from "src/inline"
import Memory from "src/memory"
import Types from "src/types"

export Types.Backend
export Types.Clock
export Types.Counts
export Types.Drain
export Types.Drained
export Types.Due
export Types.Enqueued
export Types.Fetch
export Types.Job
export Types.Later
export Types.Lease
export Types.MemoryOptions
export Types.Nack
export Types.NewJob

## Adds a job.
def enqueue(backend: Types.Backend, job: Types.NewJob) -> Result[Types.Enqueued]
  added = try backend.enqueue.call([job])
  ok(added[0])
end

## Adds the jobs, all or none, and gives one `Enqueued` for each, in order. The jobs of a batch can wait for a time or
## carry a unique key like any other.
def enqueue_all(backend: Types.Backend, jobs: List[Types.NewJob]) -> Result[List[Types.Enqueued]]
  backend.enqueue.call(jobs)
end

## A job whose payload is the JSON of the value. Set `run_at_ms`, `max_attempts` and the rest with `.with(...)`.
def json[T](queue: String, value: T) -> Types.NewJob = Types.NewJob(queue: queue, payload: JSON.encode(value).bytes)

## Reads the payload of a job as JSON of the type that the codec stands for (`User.codec`).
def decode[T](job: Types.Job, codec: Codec[T]) -> Result[T]
  text = try String.from_bytes(job.payload)
  codec.decode(text)
end

## Leases up to `options.max` jobs of a queue, waiting up to `options.wait_ms` for the first. No job in time gives
## `ok([])`.
def fetch(backend: Types.Backend, fetch: Types.Fetch) -> Result[List[Types.Lease]] = backend.fetch.call(fetch)

## Says the job is done: it is removed. A lease that ran out or was replaced fails with `jobs.lease_lost`.
def ack(backend: Types.Backend, lease: Types.Lease) -> Result[Void] = backend.ack.call(lease)

## Gives a job back: run again at a time, now without counting the attempt, or never again. Fails with
## `jobs.lease_lost` like `ack`.
def nack(backend: Types.Backend, lease: Types.Lease, how: Types.Nack) -> Result[Void] = backend.nack.call(lease, how)

## Moves the end of a lease to `ms` from now, and gives the lease with its new time. Fails with `jobs.lease_lost` like
## `ack`.
def extend(backend: Types.Backend, lease: Types.Lease, ms: Int) -> Result[Types.Lease] = backend.extend.call(lease, ms)

## How many jobs of a queue are ready, scheduled, leased and dead.
def counts(backend: Types.Backend, queue: String) -> Result[Types.Counts] = backend.counts.call(queue)

## Refuses new calls with `jobs.closed` and waits up to `drain_ms` for the backend to stop.
def close(backend: Types.Backend, drain_ms: Int) -> Void
  backend.close.call(drain_ms)
end

## What a handler returns to say that its job is dead, with no more attempts.
def discard(message: String) -> Result[Void] = error(message, kind: "jobs.discard")

## A backend that keeps its jobs in memory, in one actor: they die with the process.
def memory(options: Types.MemoryOptions = Types.MemoryOptions()) -> Result[Types.Backend] = Memory.start(options)

## A clock that moves only when told, for a backend's `clock` and for tests.
def manual_clock() -> Types.Clock
  time: ATS[String, Int] = ATS.new()
  time.put(NOW, MANUAL_START_MS)
  Types.Clock(now: -> { time.get(NOW).unwrap_or(MANUAL_START_MS) }, advance: ->(ms) { move(time, ms) })
end

## Runs the jobs of a queue one at a time in the caller, with the rules of a pipeline: `ok` acks, `Jobs.discard` makes
## the job dead, and another error runs it again after a backoff, or makes it dead on its last attempt. For the tests
## of an app: enqueue, drain, and check the effects, with no task left running.
def drain(backend: Types.Backend, options: Types.Drain, handle: Fn[Types.Job, Result[Void]]) -> Result[Types.Drained]
  Inline.drain(backend, options, handle)
end

private

NOW = "now"
# A time that looks like a real one, and is not near 0, which means "now" for `run_at_ms`.
MANUAL_START_MS = 1_700_000_000_000

def move(time: ATS[String, Int], ms: Int) -> Void
  _ = time.add(NOW, ms)
end

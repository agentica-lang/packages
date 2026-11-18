## The telemetry events of `jobs`: the calls of the facade and `Jobs.drain` go through these functions, so every
## backend gets the same events. An event says what happened, so a call that failed emits nothing. With no handler
## attached each function costs one table read: the maps of an event are built only when a handler hears it.

import Telemetry from "pkg/telemetry/telemetry"
import Types from "types"

## The span of a job that `Jobs.drain` runs: `jobs.job.start`, then `jobs.job.stop` or `jobs.job.error` (with the
## `error_kind` of the handler's error, `jobs.discard` for a job it gave up).
JOB = "jobs.job"

## `jobs.enqueue`: one event for each queue of the batch, with the jobs added (`count`) and the ones that were
## duplicates of a unique key and so were not added (`duplicate_count`): together they are the jobs offered.
def enqueue(backend: Types.Backend, jobs: List[Types.NewJob]) -> Result[List[Types.Enqueued]]
  after(ENQUEUE, backend.enqueue.call(jobs), ->(added) { enqueued(backend.name, jobs, added) })
end

## `jobs.fetch`: the jobs leased (`count`), for a fetch that leased some; an empty fetch is a poll, and says nothing.
def fetch(backend: Types.Backend, fetch: Types.Fetch) -> Result[List[Types.Lease]]
  after(FETCH, backend.fetch.call(fetch), ->(leases) { fetched(backend.name, fetch.queue, leases) })
end

## `jobs.ack`: the job is done, with the `attempt` that did it.
def ack(backend: Types.Backend, lease: Types.Lease) -> Result[Void]
  confirm(ACK, backend.ack.call(lease), -> { once(job_meta(backend.name, lease.job)) })
end

## `jobs.nack`: the job went back, and `how` is `retry`, `release` or `dead`.
def nack(backend: Types.Backend, lease: Types.Lease, how: Types.Nack) -> Result[Void]
  confirm(NACK, backend.nack.call(lease, how), -> { once(job_meta(backend.name, lease.job).put("how", how_of(how))) })
end

## `jobs.job.settle`: what a drain decided for a job, with the `verdict`: `ack`, `retry` or `dead`.
def settled(backend: Types.Backend, job: Types.Job, verdict: String) -> Void
  tell(SETTLE, -> { once(job_meta(backend.name, job).put("verdict", verdict)) })
end

## The metadata of a job: ids and names, never the payload.
def job_meta(backend: String, job: Types.Job) -> Map[String, String]
  {"queue": job.queue, "id": job.id, "attempt": job.attempt.to_s, "backend": backend}
end

private

ENQUEUE = "jobs.enqueue"
FETCH = "jobs.fetch"
ACK = "jobs.ack"
NACK = "jobs.nack"
SETTLE = "jobs.job.settle"

# What an event says: its measurements and its metadata.
struct Said
  ints: Map[String, Int]
  metadata: Map[String, String]
end

# Says the events that `build` makes when a handler hears `name`. `build` runs only then, so with no handler no map is
# built.
def tell(name: String, build: Fn[List[Said]]) -> Void
  if Telemetry.enabled?(name)
    speak(name, build.call())
  end
end

# Gives `result` as it is, and when it is `ok` tells the events of a call that gave no value.
def confirm(name: String, result: Result[Void], build: Fn[List[Said]]) -> Result[Void]
  if result.ok?
    tell(name, build)
  end

  result
end

# The same for a call that gave a value, which `build` reads.
def after[T](name: String, result: Result[T], build: Fn[T, List[Said]]) -> Result[T]
  if result.ok? and Telemetry.enabled?(name)
    speak(name, build.call(result.unwrap!))
  end

  result
end

def speak(name: String, found: List[Said]) -> Void
  for said in found
    Telemetry.execute(name, said.ints, {}, said.metadata)
  end
end

# An event of one thing that happened to one job.
def once(metadata: Map[String, String]) -> List[Said] = [Said(ints: {"count": 1}, metadata: metadata)]

def fetched(backend: String, queue: String, leases: List[Types.Lease]) -> List[Said]
  return [] if leases.empty?

  [Said(ints: {"count": leases.size}, metadata: {"queue": queue, "backend": backend})]
end

def enqueued(backend: String, jobs: List[Types.NewJob], added: List[Types.Enqueued]) -> List[Said]
  queues: List[String] = []
  seen: Map[String, Bool] = {}
  counts: Map[String, Int] = {}
  duplicates: Map[String, Int] = {}
  for position in 0...[jobs.size, added.size].min.unwrap_or(0)
    queue = jobs[position].queue
    if not seen.has_key?(queue)
      seen = seen.put(queue, true)
      queues = queues.push(queue)
    end

    if added[position].duplicate
      duplicates = duplicates.put(queue, duplicates.get(queue, 0) + 1)
    else
      counts = counts.put(queue, counts.get(queue, 0) + 1)
    end
  end

  queues.map(
    ->(queue) {
      Said(
        ints: {"count": counts.get(queue, 0), "duplicate_count": duplicates.get(queue, 0)},
        metadata: {"queue": queue, "backend": backend},
      )
    },
  )
end

def how_of(how: Types.Nack) -> String
  case how
    Types.Nack.Retry(_) -> "retry"
    Types.Nack.Release -> "release"
    Types.Nack.Dead(_) -> "dead"
  end
end

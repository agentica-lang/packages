## The telemetry events of `jobs`: the calls of the facade and `Jobs.drain` go through these functions, so every
## backend gets the same events. An event says what happened, so a call that failed emits nothing. With no handler
## attached each function costs one table read: the maps of an event are built only when a handler hears it.

import Telemetry from "pkg/telemetry/telemetry"
import Types from "types"

## The span of a job that `Jobs.drain` runs: `jobs.job.start`, then `jobs.job.stop` or `jobs.job.error` (with the
## `error_kind` of the handler's error, `jobs.discard` for a job it gave up).
JOB = "jobs.job"

## `jobs.enqueue`: one event for each queue of the batch, with the jobs added (`count`) and how many of them were
## duplicates of a unique key (`duplicate_count`).
def enqueue(backend: Types.Backend, jobs: List[Types.NewJob]) -> Result[List[Types.Enqueued]]
  added = try backend.enqueue.call(jobs)
  if Telemetry.enabled?(ENQUEUE)
    enqueued(backend.name, jobs, added)
  end

  ok(added)
end

## `jobs.fetch`: the jobs leased (`count`), for a fetch that leased some; an empty fetch is a poll, and says nothing.
def fetch(backend: Types.Backend, fetch: Types.Fetch) -> Result[List[Types.Lease]]
  leases = try backend.fetch.call(fetch)
  if not leases.empty? and Telemetry.enabled?(FETCH)
    Telemetry.execute(FETCH, {"count": leases.size}, {}, {"queue": fetch.queue, "backend": backend.name})
  end

  ok(leases)
end

## `jobs.ack`: the job is done, with the `attempt` that did it.
def ack(backend: Types.Backend, lease: Types.Lease) -> Result[Void]
  try backend.ack.call(lease)
  if Telemetry.enabled?(ACK)
    Telemetry.execute(ACK, {"count": 1}, {}, job_meta(backend.name, lease.job))
  end

  ok()
end

## `jobs.nack`: the job went back, and `how` is `retry`, `release` or `dead`.
def nack(backend: Types.Backend, lease: Types.Lease, how: Types.Nack) -> Result[Void]
  try backend.nack.call(lease, how)
  if Telemetry.enabled?(NACK)
    Telemetry.execute(NACK, {"count": 1}, {}, job_meta(backend.name, lease.job).put("how", how_of(how)))
  end

  ok()
end

## `jobs.job.settle`: what a drain decided for a job, with the `verdict`: `ack`, `retry` or `dead`.
def settled(backend: Types.Backend, job: Types.Job, verdict: String) -> Void
  if Telemetry.enabled?(SETTLE)
    Telemetry.execute(SETTLE, {"count": 1}, {}, job_meta(backend.name, job).put("verdict", verdict))
  end
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

def enqueued(backend: String, jobs: List[Types.NewJob], added: List[Types.Enqueued]) -> Void
  queues: List[String] = []
  counts: Map[String, Int] = {}
  duplicates: Map[String, Int] = {}
  for position in 0...[jobs.size, added.size].min.unwrap_or(0)
    queue = jobs[position].queue
    if not counts.has_key?(queue)
      queues = queues.push(queue)
    end

    counts = counts.put(queue, counts.get(queue, 0) + 1)
    if added[position].duplicate
      duplicates = duplicates.put(queue, duplicates.get(queue, 0) + 1)
    end
  end

  for queue in queues
    ints = {"count": counts[queue], "duplicate_count": duplicates.get(queue, 0)}
    Telemetry.execute(ENQUEUE, ints, {}, {"queue": queue, "backend": backend})
  end
end

def how_of(how: Types.Nack) -> String
  case how
    Types.Nack.Retry(_) -> "retry"
    Types.Nack.Release -> "release"
    Types.Nack.Dead(_) -> "dead"
  end
end

## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the backend: a step cannot leave tasks running, and the memory backend is one. It answers every
## request with one line, and the step program checks the line.

## A job to add: the `queue`, the payload `text`, and the settings of the job in `table` (a header, then a name and a
## value per row: `max_attempts`, `run_in_ms`, `unique_key`, `group`).
struct Add
  queue: String
  text: String
  table: List[List[String]] = []
end

## The payloads in `text`, split at the commas, in one batch.
struct Batch
  queue: String
  text: String
end

## A fetch: `name` is where the lease is kept (`name/2` for a second one), `lease_ms` the lease in ms, `max` how many
## jobs, and `limit` the `max_per_group`.
struct Take
  queue: String
  name: String
  lease_ms: Int
  max: Int = 1
  limit: Int = 0
end

## A retry of the lease `name`: `ms` from now, with `why` as the error, if there is one.
struct Backoff
  name: String
  ms: Int
  why: String = ""
end

## An extension of the lease `name` by `ms`.
struct Extension
  name: String
  ms: Int
end

## A drain of `queue`: `kind` is `ready`, `all` or `all without clock`, and `max_runs` is the most jobs it runs (0: the
## default).
struct Run
  queue: String
  kind: String
  max_runs: Int = 0
end

## A fetch that waits is parked as `name`, until `WaitEnd`. `wait_ms` is its wait (0: a very long one), and `limit` its
## `max_per_group`.
struct Park
  queue: String
  name: String
  wait_ms: Int = 0
  limit: Int = 0
end

## The end of the parked fetch `name`: the clock moves `step_ms` at a time until it ends.
struct Unpark
  name: String
  step_ms: Int = 0
end

## A stress: `consumers` tasks work off `jobs` jobs in `groups` groups (0: none), fetching with a wait of `wait_ms` (0:
## no wait) and `limit` as their `max_per_group`.
struct Crowd
  consumers: Int
  jobs: Int
  wait_ms: Int = 0
  groups: Int = 0
  limit: Int = 0
end

## A request, one for each thing a step asks of the driver. `Start` takes the settings of the backend (a header, then a
## name and a value per row: `clock` is `manual` or `wall`, `max_jobs`, `max_dead`, `fetch_timeout_ms`). `Ack`,
## `Release` and `Kill` take the name of a lease. `Counts` takes a queue, `Advance` ms, and `Close` the drain in ms.
## `Logs` is what the drains logged, one line each. `Watch` starts the hub of `telemetry` and captures the events that
## match the patterns, and `Events` and `EventNames` read the events since the last read, one line each or only their
## names, after a check of each against the conventions.
enum Request
  Start(List[List[String]])
  Advance(Int)
  Close(Int)
  Enqueue(Add)
  EnqueueAll(Batch)
  Fetch(Take)
  Ack(String)
  Retry(Backoff)
  Release(String)
  Kill(String)
  Extend(Extension)
  Counts(String)
  Drain(Run)
  Logs
  Wait(Park)
  WaitEnd(Unpark)
  Stress(Crowd)
  Watch(List[String])
  Events
  EventNames
end

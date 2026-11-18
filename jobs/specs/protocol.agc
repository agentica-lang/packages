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

## The payloads in `text`, split at the commas, in one batch. `keys` are the unique keys of the jobs, in order (an empty
## key for none, and fewer keys than jobs leave the last ones with none).
struct Batch
  queue: String
  text: String
  keys: List[String] = []
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

## Which jobs a drain runs: the ones that are due (`Ready`), also the ones that wait for a time, with the clock of the
## backend (`All`), or with no clock, which a drain refuses (`AllWithoutClock`).
enum Mode
  Ready
  All
  AllWithoutClock
end

## A drain of `queue`, and `max_runs` is the most jobs it runs (0: the default).
struct Run
  queue: String
  mode: Mode
  max_runs: Int = 0
end

## The clock of a backend: one that moves only when a step says so, or the wall clock.
enum Clocking
  Manual
  Wall
end

## The settings of a backend: `max_jobs` and `max_dead` as in `Jobs.MemoryOptions`, and `fetch_timeout_ms` when it has
## one.
struct Settings
  clock: Clocking = Clocking.Manual
  max_jobs: Int = 10_000
  max_dead: Int = 1_000
  fetch_timeout_ms: Optional[Int] = none
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

## A request, one for each thing a step asks of the driver. `Start` takes the settings of the backend. `Ack`,
## `Release` and `Kill` take the name of a lease. `Counts` takes a queue, `Advance` ms, and `Close` the drain in ms.
## `Logs` is what the drains logged, one line each. `Watch` starts the hub of `telemetry` and captures the events that
## match the patterns, and `Events` and `EventNames` read the events since the last read, one line each or only their
## names, after a check of each against the conventions.
enum Request
  Start(Settings)
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

## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the backend: a step cannot leave tasks running, and the memory backend is one. It answers every
## request with one line, and the step program checks the line.

## A request. The ops are `start` (table: the settings, a header and a name and value per row: `clock` is `manual` or
## `wall`, `max_jobs`, `max_dead`, `fetch_timeout_ms`), `enqueue` (queue, text: the payload, table: the settings of the
## job: `max_attempts`, `run_in_ms`, `unique_key`), `enqueue_all` (queue, text: the payloads, split at the commas),
## `fetch` (queue, name: where to keep the lease, `name/2` for a second one, number: the lease in ms, max: how many
## jobs), `ack`, `retry` (number: ms from now, text: what went wrong, if anything), `release`, `kill` and `extend`
## (number: ms) of the lease `name`, `counts` (queue), `advance` (number: ms), `drain` (queue, kind: `ready`, `all` or
## `all without clock`, number: `max_runs` if there is one), `wait` (queue, name: a fetch that waits is parked;
## `wait_end` ends it; number: its `wait_ms` if there is one), `close` (number: the drain in ms), and `stress` (number:
## the consumers, wait: the jobs, wait_ms: how long a consumer waits for a job, if it does).
struct Request
  op: String
  queue: String = ""
  name: String = ""
  text: String = ""
  kind: String = ""
  number: Int = 0
  wait: Int = 0
  wait_ms: Int = 0
  max: Int = 1
  table: List[List[String]] = []
end

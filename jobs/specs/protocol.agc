## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the backend: a step cannot leave tasks running, and the memory backend is one. It answers every
## request with one line, and the step program checks the line.

## A request. The ops are `start` (table: the settings, a header and a name and value per row: `clock` is `manual` or
## `wall`, `max_jobs`, `max_dead`), `enqueue` (queue, text: the payload, table: the settings of the job:
## `max_attempts`, `run_in_ms`, `unique_key`), `fetch` (queue, name: where to keep the lease, number: the lease in ms),
## `ack`, `retry` (number: ms from now), `release`, `kill` and `extend` (number: ms) of the lease `name`, `counts`
## (queue), `advance` (number: ms), `drain` (queue, kind: `ready` or `all`), `wait` (queue, name: a fetch that waits is
## parked; `wait_end` ends it), `close` (number: the drain in ms), and `stress` (number: the consumers, wait: the
## jobs).
struct Request
  op: String
  queue: String = ""
  name: String = ""
  text: String = ""
  kind: String = ""
  number: Int = 0
  wait: Int = 0
  table: List[List[String]] = []
end

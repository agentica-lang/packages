## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the pool and the jobs that use it: a step program cannot keep tasks between its steps, so each
## scenario starts a driver process and talks to it. The driver answers every request with one line: `ok`, or the
## reason the request or the expectation failed.

## The reply that means the request worked.
OK = "ok"

## A request. The ops are `start`, `start_owned` (in a task that `end_starter` ends) and `start_fails` (table: the
## settings, a header and a name and value per row; text: for `start_fails`, the start of the error), `job` (name, kind:
## `holds`, `probe`, `loops`, `crashes`, `fails`, `hangs` or `nests` (a checkout inside the body), number: the
## milliseconds a `holds` job keeps its resource, or a `loops` job runs, times: how many times a `holds` job takes one
## in turn), `flood` (number: the callers, wait: the milliseconds each one holds its resource, times: how many times
## each takes one), `cancel_job` (name), `race_crash` (number: the callers, one after the other, wait: the milliseconds before the body of each crashes, which is when its caller is cancelled), `wait_jobs`, `sleep` (number), `close` (number: the drain in milliseconds), and
## the expectations `expect_job` (name, text: the start of its result), `expect_timeout` (name; kind `or_ok` lets it
## succeed too), `expect_kind` (name, text: the start of the kind of its error), `expect_order` (text: the names in the
## order they finished, joined by commas), `expect_count` (name: the counter, number: its value, kind: `is` or
## `reaches`, wait: the milliseconds to wait for it), and `expect_pool_count` (the same, for a count of the pool) and `expect_one_task` (the checkout and the body of the last
## resource lent ran in one task).
struct Request
  op: String
  name: String = ""
  kind: String = ""
  text: String = ""
  number: Int = 0
  wait: Int = 0
  times: Int = 0
  table: List[List[String]] = []
end

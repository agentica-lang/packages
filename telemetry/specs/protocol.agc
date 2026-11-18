## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the hub: a step cannot leave tasks running, and the hub and its handlers are tasks. It answers
## every request with one line, and the step program checks the line.

## A request. The ops are `start`, `stop` (number: the timeout in ms), `attach` (id, patterns, mode: how the handler
## acts, `record`, `fail`, `crash` or `block`; number: the capacity, 0 for the default), `detach` (id), `execute` (name
## and a table of rows `kind`, `key`, `value`, where the kind is `int`, `float` or `meta`), `flood` (name, number: how
## many events), `flush`, `release` (id: a blocked handler goes on), `handlers`, `enabled` (name), `dropped` (id),
## `log` (id: the events it recorded), `warnings` (what the Logger got), `idle` (waits for the tasks to end) and
## `stress` (number: the tasks, wait: the events of each).
struct Request
  op: String
  id: String = ""
  name: String = ""
  mode: String = "record"
  patterns: List[String] = []
  number: Int = 0
  wait: Int = 0
  table: List[List[String]] = []
end

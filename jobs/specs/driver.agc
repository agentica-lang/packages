## The program under test of the features: it holds one memory backend, a clock, and the leases that the steps named,
## and runs the requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## Replies: `ok`, `ok ID` (an enqueue; `ok ID duplicate` for one that was), `ok PAYLOAD attempt N` (a fetch, with
## the last error and the group of the job when it has them, and `, ` between the jobs when it gave more than one;
## `ok none` when it gave none), `ready N scheduled N leased N dead N` (counts), `done N retried N dead N` (a drain),
## and `error KIND` for a failed call.
##
## The payload of a job says what a drain does with it: `ok` acks it, `fail` returns an error, `discard` discards it,
## and `fail once` fails the first attempt only.

import Conformance from "pkg/telemetry/conformance"
import Jobs from "../jobs"
import Logger from "std/logger"
import Stress from "stress"
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"
import {Request} from "protocol"

private

POLL_MS = 20
EVENT_NUMBERS = ["count", "duplicate_count"]
EVENT_WORDS = ["attempt", "how", "verdict", "error_kind"]
PARK_MS = 100
WAIT_FETCH_MS = 3_600_000
DRAIN_RUNS = 1_000

struct Driver
  backend: Optional[Jobs.Backend]
  clock: Jobs.Clock
  held: Map[String, Jobs.Lease]
  waiting: Map[String, Task[Result[List[Jobs.Lease]]]]
  logs: ATS[String, Int]
  events: Optional[Testing.Capture]
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  driver = Driver(backend: none, clock: Jobs.manual_clock(), held: {}, waiting: {}, logs: ATS.new(), events: none)
  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
end

def handle(driver: Driver, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> Handled(driver: driver, reply: "bad request: #{message}")
    ok(req) -> act(driver, req)
  end
end

def act(driver: Driver, req: Request) -> Handled
  case req.op
    "start" -> start(driver, req)
    "advance" -> advance(driver, req)
    "close" -> with_backend(driver, req, &close)
    "enqueue" -> with_backend(driver, req, &enqueue)
    "enqueue_all" -> with_backend(driver, req, &enqueue_all)
    "fetch" -> with_backend(driver, req, &fetch)
    "ack" -> with_backend(driver, req, &ack)
    "retry" -> with_backend(driver, req, &retry)
    "release" -> with_backend(driver, req, &release)
    "kill" -> with_backend(driver, req, &kill)
    "extend" -> with_backend(driver, req, &extend)
    "counts" -> with_backend(driver, req, &counts)
    "drain" -> with_backend(driver, req, &drain)
    "logs" -> logs(driver)
    "watch" -> watch(driver, req)
    "events" -> Handled(driver: driver, reply: events(driver, req.kind == "names"))
    "wait" -> with_backend(driver, req, &wait)
    "wait_end" -> with_backend(driver, req, &wait_end)
    "stress" -> with_backend(driver, req, &stress)
    _ -> Handled(driver: driver, reply: "unknown op #{req.op}")
  end
end

def with_backend(driver: Driver, req: Request, run: Fn[Driver, Jobs.Backend, Request, Handled]) -> Handled
  case driver.backend
    some(backend) -> run.call(driver, backend, req)
    none -> Handled(driver: driver, reply: "no backend: start one first")
  end
end

# The settings of a table (a header, then a name and a value per row).
def settings(req: Request) -> Map[String, String]
  rows = req.table.drop(1)
  rows.reduce({}, ->(acc, row) { acc.put(row[0], row[1]) })
end

def number(values: Map[String, String], name: String, default: Int) -> Int
  case values.get(name)
    some(text) -> text.to_i.unwrap_or(default)
    none -> default
  end
end

def start(driver: Driver, req: Request) -> Handled
  values = settings(req)
  clock = if_manual(values)
  options = Jobs.MemoryOptions(
    max_jobs: number(values, "max_jobs", 10_000),
    max_dead: number(values, "max_dead", 1_000),
    clock: some(clock.now),
    fetch_timeout_ms: fetch_timeout(values),
  )

  case Jobs.memory(options)
    ok(backend) ->
      Handled(
        driver: Driver(
          backend: some(backend),
          clock: clock,
          held: {},
          waiting: {},
          logs: driver.logs,
          events: driver.events,
        ),
        reply: "ok",
      )
    error(e) -> Handled(driver: driver, reply: failure(e))
  end
end

# A manual clock, or one that reads the wall clock (the steps do not move it).
def if_manual(values: Map[String, String]) -> Jobs.Clock
  case values.get("clock", "manual")
    "wall" -> Jobs.Clock(now: &Time.now_ms, advance: ->(_ms) { nil })
    _ -> Jobs.manual_clock()
  end
end

def fetch_timeout(values: Map[String, String]) -> Optional[Int]
  case values.get("fetch_timeout_ms")
    some(text) -> some(text.to_i.unwrap_or(0))
    none -> none
  end
end

def failure(e: Error) -> String = "error #{e.kind}"

def answer[T](driver: Driver, result: Result[T], good: Fn[T, String]) -> Handled
  case result
    ok(value) -> Handled(driver: driver, reply: good.call(value))
    error(e) -> Handled(driver: driver, reply: failure(e))
  end
end

def done(driver: Driver, result: Result[Void]) -> Handled
  case result
    ok(_) -> Handled(driver: driver, reply: "ok")
    error(e) -> Handled(driver: driver, reply: failure(e))
  end
end

def advance(driver: Driver, req: Request) -> Handled
  driver.clock.advance.call(req.number)
  Handled(driver: driver, reply: "ok")
end

def close(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  Jobs.close(backend, req.number)
  Handled(driver: driver, reply: "ok")
end

def enqueue(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  values = settings(req)
  at_ms = number(values, "run_in_ms", 0)
  new = Jobs.NewJob(
    queue: req.queue,
    payload: req.text.bytes,
    max_attempts: number(values, "max_attempts", 5),
    run_at_ms: if_later(driver, at_ms),
    unique_key: values.get("unique_key"),
    group: values.get("group"),
  )

  answer(driver, Jobs.enqueue(backend, new), ->(added) { enqueued_text(added) })
end

# The payloads of the text, split at the commas, in one batch.
def enqueue_all(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  jobs = req.text.split(",").map(->(text) { Jobs.NewJob(queue: req.queue, payload: text.bytes) })
  answer(driver, Jobs.enqueue_all(backend, jobs), ->(added) { "ok #{added.map(->(one) { one.id }).join(",")}" })
end

# 0 is now; a wait of `ms` is the clock plus that.
def if_later(driver: Driver, ms: Int) -> Int
  return 0 if ms == 0

  driver.clock.now.call() + ms
end

def enqueued_text(added: Jobs.Enqueued) -> String
  return "ok #{added.id} duplicate" if added.duplicate

  "ok #{added.id}"
end

def fetch(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  leases = Jobs.fetch(
    backend,
    Jobs.Fetch(queue: req.queue, max: req.max, lease_ms: req.number, max_per_group: req.limit),
  )

  case leases
    error(e) -> Handled(driver: driver, reply: failure(e))
    ok(found) if found.empty? -> Handled(driver: driver, reply: "ok none")
    ok(found) -> kept(driver, req.name, found)
  end
end

# The first lease is kept as `name`, the next ones as `name/2`, `name/3`...
def kept(driver: Driver, name: String, leases: List[Jobs.Lease]) -> Handled
  held = driver.held
  for position in 0...leases.size
    held = held.put(lease_name(name, position), leases[position])
  end

  Handled(driver: driver.with(held: held), reply: "ok #{leases.map(->(lease) { lease_text(lease) }).join(", ")}")
end

def lease_name(name: String, position: Int) -> String
  return name if position == 0

  "#{name}/#{position + 1}"
end

def lease_text(lease: Jobs.Lease) -> String
  text = String.from_bytes(lease.job.payload).unwrap_or("?")
  base = "#{text} attempt #{lease.job.attempt}"
  with_error = case lease.job.last_error
    some(why) -> "#{base} last_error #{why}"
    none -> base
  end

  case lease.job.group
    some(group) -> "#{with_error} group #{group}"
    none -> with_error
  end
end

def with_lease(driver: Driver, name: String, run: Fn[Jobs.Lease, Result[Void]]) -> Handled
  case driver.held.get(name)
    some(lease) -> done(driver, run.call(lease))
    none -> Handled(driver: driver, reply: "no lease named #{name}")
  end
end

def ack(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  with_lease(driver, req.name, ->(lease) { Jobs.ack(backend, lease) })
end

def retry(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  at_ms = driver.clock.now.call() + req.number
  later = Jobs.Later(at_ms: at_ms, error: why(req.text))
  with_lease(driver, req.name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Retry(later)) })
end

def why(text: String) -> Optional[String]
  return none if text == ""

  some(text)
end

def release(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  with_lease(driver, req.name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Release) })
end

def kill(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  with_lease(driver, req.name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Dead("killed")) })
end

def extend(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  case driver.held.get(req.name)
    some(lease) ->
      case Jobs.extend(backend, lease, req.number)
        ok(longer) -> Handled(driver: driver.with(held: driver.held.put(req.name, longer)), reply: "ok")
        error(e) -> Handled(driver: driver, reply: failure(e))
      end

    none -> Handled(driver: driver, reply: "no lease named #{req.name}")
  end
end

def counts(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  answer(driver, Jobs.counts(backend, req.queue), ->(c) { counts_text(c) })
end

def counts_text(c: Jobs.Counts) -> String
  "ready #{c.ready} scheduled #{c.scheduled} leased #{c.leased} dead #{c.dead}"
end

# A fetch that waits: it runs in a task of the driver until `wait_end`.
def wait(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  wait_ms = if_given(req.number, WAIT_FETCH_MS)
  fetch_args = Jobs.Fetch(queue: req.queue, lease_ms: 60_000, wait_ms: wait_ms, max_per_group: req.limit)
  task = Task.spawn do Jobs.fetch(backend, fetch_args) end
  # The fetch is parked before the next request, so the waiting fetches keep the order of their steps.
  Task.sleep(PARK_MS)
  Handled(driver: driver.with(waiting: driver.waiting.put(req.name, task)), reply: "ok")
end

# The result of the waiting fetch: the clock moves (`number` ms) until it ends, so that it does not matter when the
# fetch began to wait.
def wait_end(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  case driver.waiting.get(req.name)
    some(task) -> waited(driver, task, req)
    none -> Handled(driver: driver, reply: "no waiting fetch named #{req.name}")
  end
end

def waited(driver: Driver, task: Task[Result[List[Jobs.Lease]]], req: Request) -> Handled
  tries = 0
  while tries < 1_000
    case Task.await(task, POLL_MS)
      Await.Done(result) -> return waited_text(driver, req.name, result)
      Await.TimedOut -> driver.clock.advance.call(req.number)
    end

    tries += 1
  end

  Handled(driver: driver, reply: "the waiting fetch did not end")
end

def waited_text(driver: Driver, name: String, result: Result[List[Jobs.Lease]]) -> Handled
  case result
    error(e) -> Handled(driver: driver, reply: failure(e))
    ok(found) if found.empty? -> Handled(driver: driver, reply: "ok none")
    ok(found) -> kept(driver, name, found)
  end
end

def drain(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  plan = Jobs.Drain(
    queue: req.queue,
    due: due_of(req.kind),
    max_runs: if_given(req.number, DRAIN_RUNS),
    clock: clock_for(driver, req.kind),
  )

  drained = captured(driver, -> { Jobs.drain(backend, plan) do |job| behave(job) end })
  answer(driver, drained, ->(d) { "done #{d.done} retried #{d.retried} dead #{d.dead}" })
end

def due_of(kind: String) -> Jobs.Due
  case kind
    "ready" -> Jobs.Due.Ready
    _ -> Jobs.Due.All
  end
end

def clock_for(driver: Driver, kind: String) -> Optional[Jobs.Clock]
  return none if kind == "all without clock"

  some(driver.clock)
end

# The number of a request, or the default when the request has none.
def if_given(value: Int, default: Int) -> Int
  return default if value == 0

  value
end

# What a drain logs: the level, the message and the fields in the order of their names, to be read with `logs`. Each
# line has its number in front, so a line that came twice is kept twice.
def captured[T](driver: Driver, run: Fn[T]) -> T
  _ = Logger.attach("capture", Logger.Level.Debug) do |event|
    driver.logs.put("#{driver.logs.size}\t#{log_line(event)}", driver.logs.size)
  end

  result = run.call()
  _ = Logger.detach("capture")
  result
end

def log_line(event: Logger.Event) -> String
  fields = event.fields.keys.sort.map(->(name) { "#{name}=#{event.fields[name]}" })
  "#{level_name(event.level)} #{event.message} #{fields.join(" ")}"
end

def level_name(level: Logger.Level) -> String
  case level
    Logger.Level.Debug -> "debug"
    Logger.Level.Info -> "info"
    Logger.Level.Warning -> "warning"
    Logger.Level.Error -> "err"
  end
end

def logs(driver: Driver) -> Handled
  lines = driver.logs.to_map
  ordered = lines.keys.sort_by(->(line) { lines[line] })
  Handled(driver: driver, reply: ordered.map(->(line) { line.split("\t")[1] }).join("; "))
end

def behave(job: Jobs.Job) -> Result[Void]
  case String.from_bytes(job.payload).unwrap_or("")
    "ok" -> ok()
    "discard" -> Jobs.discard("not worth a retry")
    "fail once" if job.attempt == 1 -> error("first attempt fails")
    "fail once" -> ok()
    _ -> error("fails")
  end
end

def plan_of(req: Request) -> Stress.Plan
  Stress.Plan(consumers: req.number, jobs: req.wait, wait_ms: req.wait_ms, groups: req.groups, limit: req.limit)
end

def stress(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  Handled(driver: driver, reply: Stress.run(backend, driver.clock, plan_of(req), driver.events))
end

# The hub of `telemetry`, and a capture of the events of `jobs`: it runs in the main task, like the backend's actor.
def watch(driver: Driver, req: Request) -> Handled
  _ = Telemetry.start()
  case Testing.capture(req.text.split(","))
    ok(made) -> Handled(driver: driver.with(events: some(made)), reply: "ok")
    error(e) -> Handled(driver: driver, reply: failure(e))
  end
end

# The events since the last read, one line each: the name, the queue, and the numbers and words that the steps check.
# An event that breaks the conventions of `telemetry` is the reply instead.
def events(driver: Driver, names_only: Bool) -> String
  case driver.events
    some(made) -> read_events(made, names_only)
    none -> "no watch: say so first"
  end
end

def read_events(made: Testing.Capture, names_only: Bool) -> String
  case Testing.events(made)
    error(e) -> failure(e)
    ok(found) -> lines_of(found, names_only)
  end
end

def lines_of(found: List[Telemetry.Event], names_only: Bool) -> String
  for event in found
    case Conformance.check(event)
      error(e) -> return "#{event.name} breaks the conventions: #{e.kind}"
      ok(_) -> nil
    end
  end

  return "ok" if found.empty?

  return "ok #{found.map(->(event) { event.name }).join("; ")}" if names_only

  "ok #{found.map(->(event) { event_line(event) }).join("; ")}"
end

def event_line(event: Telemetry.Event) -> String
  words = EVENT_WORDS.filter(->(key) { event.metadata.has_key?(key) }).map(->(key) { "#{key}=#{event.metadata[key]}" })
  numbers = EVENT_NUMBERS.filter(->(key) { event.ints.has_key?(key) }).map(->(key) { "#{key}=#{event.ints[key]}" })
  ([event.name, event.metadata.get("queue", "")] + numbers + words).join(" ")
end

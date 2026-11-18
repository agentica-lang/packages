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
import {
  Add, Backoff, Batch, Clocking, Crowd, Extension, Mode, Park, Request, Run, Settings, Take, Unpark,
} from "protocol"

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
  case req
    Request.Start(settings) -> start(driver, settings)
    Request.Advance(ms) -> advance(driver, ms)
    Request.Close(ms) -> with_backend(driver, ->(backend) { close(driver, backend, ms) })
    Request.Enqueue(add) -> with_backend(driver, ->(backend) { enqueue(driver, backend, add) })
    Request.EnqueueAll(batch) -> with_backend(driver, ->(backend) { enqueue_all(driver, backend, batch) })
    Request.Fetch(take) -> with_backend(driver, ->(backend) { fetch(driver, backend, take) })
    Request.Ack(name) -> with_backend(driver, ->(backend) { ack(driver, backend, name) })
    Request.Retry(backoff) -> with_backend(driver, ->(backend) { retry(driver, backend, backoff) })
    Request.Release(name) -> with_backend(driver, ->(backend) { release(driver, backend, name) })
    Request.Kill(name) -> with_backend(driver, ->(backend) { kill(driver, backend, name) })
    Request.Extend(extension) -> with_backend(driver, ->(backend) { extend(driver, backend, extension) })
    Request.Counts(queue) -> with_backend(driver, ->(backend) { counts(driver, backend, queue) })
    Request.Drain(run) -> with_backend(driver, ->(backend) { drain(driver, backend, run) })
    Request.Logs -> logs(driver)
    Request.Watch(patterns) -> watch(driver, patterns)
    Request.Events -> Handled(driver: driver, reply: events(driver, false))
    Request.EventNames -> Handled(driver: driver, reply: events(driver, true))
    Request.Wait(park) -> with_backend(driver, ->(backend) { wait(driver, backend, park) })
    Request.WaitEnd(unpark) -> with_backend(driver, ->(_backend) { wait_end(driver, unpark) })
    Request.Stress(crowd) -> with_backend(driver, ->(backend) { stress(driver, backend, crowd) })
  end
end

def with_backend(driver: Driver, run: Fn[Jobs.Backend, Handled]) -> Handled
  case driver.backend
    some(backend) -> run.call(backend)
    none -> Handled(driver: driver, reply: "no backend: start one first")
  end
end

# The settings of a table (a header, then a name and a value per row).
def settings(table: List[List[String]]) -> Map[String, String]
  rows = table.drop(1)
  rows.reduce({}, ->(acc, row) { acc.put(row[0], row[1]) })
end

def number(values: Map[String, String], name: String, default: Int) -> Int
  case values.get(name)
    some(text) -> text.to_i.unwrap_or(default)
    none -> default
  end
end

def start(driver: Driver, settings: Settings) -> Handled
  clock = clock_of(settings.clock)
  options = Jobs.MemoryOptions(
    max_jobs: settings.max_jobs,
    max_dead: settings.max_dead,
    clock: some(clock.now),
    fetch_timeout_ms: settings.fetch_timeout_ms,
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
def clock_of(clocking: Clocking) -> Jobs.Clock
  case clocking
    Clocking.Wall -> Jobs.Clock(now: &Time.now_ms, advance: ->(_ms) { nil })
    Clocking.Manual -> Jobs.manual_clock()
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

def advance(driver: Driver, ms: Int) -> Handled
  driver.clock.advance.call(ms)
  Handled(driver: driver, reply: "ok")
end

def close(driver: Driver, backend: Jobs.Backend, ms: Int) -> Handled
  Jobs.close(backend, ms)
  Handled(driver: driver, reply: "ok")
end

def enqueue(driver: Driver, backend: Jobs.Backend, add: Add) -> Handled
  values = settings(add.table)
  at_ms = number(values, "run_in_ms", 0)
  new = Jobs.NewJob(
    queue: add.queue,
    payload: add.text.bytes,
    max_attempts: number(values, "max_attempts", 5),
    run_at_ms: if_later(driver, at_ms),
    unique_key: values.get("unique_key"),
    group: values.get("group"),
  )

  answer(driver, Jobs.enqueue(backend, new), ->(added) { enqueued_text(added) })
end

# The payloads of the text, split at the commas, in one batch.
# The unique key of the job at a position of a batch, if the batch gives one.
def key_of(keys: List[String], position: Int) -> Optional[String]
  return none if position >= keys.size or keys[position] == ""

  some(keys[position])
end

def enqueue_all(driver: Driver, backend: Jobs.Backend, batch: Batch) -> Handled
  jobs = batch.text.split(",").map(->(text) { Jobs.NewJob(queue: batch.queue, payload: text.bytes) })
  jobs = (0...jobs.size).map(->(position) { jobs[position].with(unique_key: key_of(batch.keys, position)) })
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

def fetch(driver: Driver, backend: Jobs.Backend, take: Take) -> Handled
  leases = Jobs.fetch(
    backend,
    Jobs.Fetch(queue: take.queue, max: take.max, lease_ms: take.lease_ms, max_per_group: take.limit),
  )

  case leases
    error(e) -> Handled(driver: driver, reply: failure(e))
    ok(found) if found.empty? -> Handled(driver: driver, reply: "ok none")
    ok(found) -> kept(driver, take.name, found)
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

def ack(driver: Driver, backend: Jobs.Backend, name: String) -> Handled
  with_lease(driver, name, ->(lease) { Jobs.ack(backend, lease) })
end

def retry(driver: Driver, backend: Jobs.Backend, backoff: Backoff) -> Handled
  at_ms = driver.clock.now.call() + backoff.ms
  later = Jobs.Later(at_ms: at_ms, error: why(backoff.why))
  with_lease(driver, backoff.name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Retry(later)) })
end

def why(text: String) -> Optional[String]
  return none if text == ""

  some(text)
end

def release(driver: Driver, backend: Jobs.Backend, name: String) -> Handled
  with_lease(driver, name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Release) })
end

def kill(driver: Driver, backend: Jobs.Backend, name: String) -> Handled
  with_lease(driver, name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Dead("killed")) })
end

def extend(driver: Driver, backend: Jobs.Backend, extension: Extension) -> Handled
  case driver.held.get(extension.name)
    some(lease) ->
      case Jobs.extend(backend, lease, extension.ms)
        ok(longer) -> Handled(driver: driver.with(held: driver.held.put(extension.name, longer)), reply: "ok")
        error(e) -> Handled(driver: driver, reply: failure(e))
      end

    none -> Handled(driver: driver, reply: "no lease named #{extension.name}")
  end
end

def counts(driver: Driver, backend: Jobs.Backend, queue: String) -> Handled
  answer(driver, Jobs.counts(backend, queue), ->(c) { counts_text(c) })
end

def counts_text(c: Jobs.Counts) -> String
  "ready #{c.ready} scheduled #{c.scheduled} leased #{c.leased} dead #{c.dead}"
end

# A fetch that waits: it runs in a task of the driver until `wait_end`.
def wait(driver: Driver, backend: Jobs.Backend, park: Park) -> Handled
  wait_ms = if_given(park.wait_ms, WAIT_FETCH_MS)
  fetch_args = Jobs.Fetch(queue: park.queue, lease_ms: 60_000, wait_ms: wait_ms, max_per_group: park.limit)
  task = Task.spawn do Jobs.fetch(backend, fetch_args) end
  # The fetch is parked before the next request, so the waiting fetches keep the order of their steps.
  Task.sleep(PARK_MS)
  Handled(driver: driver.with(waiting: driver.waiting.put(park.name, task)), reply: "ok")
end

# The result of the waiting fetch: the clock moves (`number` ms) until it ends, so that it does not matter when the
# fetch began to wait.
def wait_end(driver: Driver, unpark: Unpark) -> Handled
  case driver.waiting.get(unpark.name)
    some(task) -> waited(driver, task, unpark)
    none -> Handled(driver: driver, reply: "no waiting fetch named #{unpark.name}")
  end
end

def waited(driver: Driver, task: Task[Result[List[Jobs.Lease]]], unpark: Unpark) -> Handled
  tries = 0
  while tries < 1_000
    case Task.await(task, POLL_MS)
      Await.Done(result) -> return waited_text(driver, unpark.name, result)
      Await.TimedOut -> driver.clock.advance.call(unpark.step_ms)
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

def drain(driver: Driver, backend: Jobs.Backend, spec: Run) -> Handled
  plan = Jobs.Drain(
    queue: spec.queue,
    due: due_of(spec.mode),
    max_runs: if_given(spec.max_runs, DRAIN_RUNS),
    clock: clock_for(driver, spec.mode),
  )

  drained = captured(driver, -> { Jobs.drain(backend, plan) do |job| behave(job) end })
  answer(driver, drained, ->(d) { "done #{d.done} retried #{d.retried} dead #{d.dead}" })
end

def due_of(mode: Mode) -> Jobs.Due
  case mode
    Mode.Ready -> Jobs.Due.Ready
    Mode.All -> Jobs.Due.All
    Mode.AllWithoutClock -> Jobs.Due.All
  end
end

def clock_for(driver: Driver, mode: Mode) -> Optional[Jobs.Clock]
  case mode
    Mode.Ready -> some(driver.clock)
    Mode.All -> some(driver.clock)
    Mode.AllWithoutClock -> none
  end
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

def plan_of(crowd: Crowd) -> Stress.Plan
  Stress.Plan(
    consumers: crowd.consumers,
    jobs: crowd.jobs,
    wait_ms: crowd.wait_ms,
    groups: crowd.groups,
    limit: crowd.limit,
  )
end

def stress(driver: Driver, backend: Jobs.Backend, crowd: Crowd) -> Handled
  Handled(driver: driver, reply: Stress.run(backend, driver.clock, plan_of(crowd), driver.events))
end

# The hub of `telemetry`, and a capture of the events of `jobs`: it runs in the main task, like the backend's actor.
def watch(driver: Driver, patterns: List[String]) -> Handled
  _ = Telemetry.start()
  case Testing.capture(patterns)
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

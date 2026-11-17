## The program under test of the features: it holds one memory backend, a clock, and the leases that the steps named,
## and runs the requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## Replies: `ok`, `ok ID` (an enqueue; `ok ID duplicate` for one that was), `ok PAYLOAD attempt N` (a fetch; `ok none`
## when it gave no job), `ready N scheduled N leased N dead N` (counts), `done N retried N dead N` (a drain), and
## `error KIND` for a failed call.
##
## The payload of a job says what a drain does with it: `ok` acks it, `fail` returns an error, `discard` discards it,
## and `fail once` fails the first attempt only.

import Jobs from "../jobs"
import Stress from "stress"
import {Request} from "protocol"

private

POLL_MS = 20
WAIT_FETCH_MS = 3_600_000

struct Driver
  backend: Optional[Jobs.Backend]
  clock: Jobs.Clock
  held: Map[String, Jobs.Lease]
  waiting: Map[String, Task[Result[List[Jobs.Lease]]]]
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  driver = Driver(backend: none, clock: Jobs.manual_clock(), held: {}, waiting: {})
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
    "fetch" -> with_backend(driver, req, &fetch)
    "ack" -> with_backend(driver, req, &ack)
    "retry" -> with_backend(driver, req, &retry)
    "release" -> with_backend(driver, req, &release)
    "kill" -> with_backend(driver, req, &kill)
    "extend" -> with_backend(driver, req, &extend)
    "counts" -> with_backend(driver, req, &counts)
    "drain" -> with_backend(driver, req, &drain)
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
  )

  case Jobs.memory(options)
    ok(backend) -> Handled(driver: Driver(backend: some(backend), clock: clock, held: {}, waiting: {}), reply: "ok")
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
  )

  answer(driver, Jobs.enqueue(backend, new), ->(added) { enqueued_text(added) })
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
  leases = Jobs.fetch(backend, Jobs.Fetch(queue: req.queue, lease_ms: req.number))
  case leases
    error(e) -> Handled(driver: driver, reply: failure(e))
    ok(found) if found.empty? -> Handled(driver: driver, reply: "ok none")
    ok(found) -> kept(driver, req.name, found[0])
  end
end

def kept(driver: Driver, name: String, lease: Jobs.Lease) -> Handled
  text = String.from_bytes(lease.job.payload).unwrap_or("?")
  Handled(driver: driver.with(held: driver.held.put(name, lease)), reply: "ok #{text} attempt #{lease.job.attempt}")
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
  with_lease(driver, req.name, ->(lease) { Jobs.nack(backend, lease, Jobs.Nack.Retry(at_ms)) })
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
  fetch_args = Jobs.Fetch(queue: req.queue, lease_ms: 60_000, wait_ms: WAIT_FETCH_MS)
  task = Task.spawn do Jobs.fetch(backend, fetch_args) end
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
    ok(found) -> kept(driver, name, found[0])
  end
end

def drain(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  plan = Jobs.Drain(queue: req.queue, due: due_of(req.kind), clock: some(driver.clock))
  drained = Jobs.drain(backend, plan) do |job| behave(job) end
  answer(driver, drained, ->(d) { "done #{d.done} retried #{d.retried} dead #{d.dead}" })
end

def due_of(kind: String) -> Jobs.Due
  case kind
    "all" -> Jobs.Due.All
    _ -> Jobs.Due.Ready
  end
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

def stress(driver: Driver, backend: Jobs.Backend, req: Request) -> Handled
  Handled(driver: driver, reply: Stress.run(backend, driver.clock, req.number, req.wait))
end

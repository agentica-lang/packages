## The program under test of the features: it holds the hub and the handlers that the steps attached, and runs the
## requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## Replies: `ok`, `ok TEXT` (a read) and `error KIND` for a failed call. A handler records the events it gets in a
## table of this program, which a step reads after `flush`.

import Actor from "std/actor"
import Logger from "std/logger"
import Hub from "../src/hub"
import Routes from "../src/routes"
import Testing from "../testing"
import Starts from "starts"
import Stress from "stress"
import Telemetry from "../telemetry"
import Types from "../src/types"
import {Request} from "protocol"

private

# What the Logger got at warning level, and what each handler recorded.
WARNINGS: ATS[String, List[String]] = ATS.new()
LOGS: ATS[String, List[String]] = ATS.new()
IDLE_MS = 2_000
BLOCK_MS = 10_000
SLOW_MS = 20
BUSY_MAX_MS = 1_300
FLUSH_BUDGET_MS = 300
FLUSH_SLACK_MS = 300
FLUSH_MS = 500

struct Driver
  gates: Map[String, Channel[Bool]]
  captures: Map[String, Testing.Capture] = {}
  starter: Optional[Task[Void]] = none
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  driver = Driver(gates: {})
  _ = Logger.attach("capture", Logger.Level.Warning, &capture)
  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
end

def capture(event: Logger.Event) -> Void
  _ = WARNINGS.push("all", "#{event.message} #{event.fields}")
  nil
end

def handle(driver: Driver, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> Handled(driver: driver, reply: "bad request: #{message}")
    ok(req) -> act(driver, req)
  end
end

def act(driver: Driver, req: Request) -> Handled
  case req.op
    "start" -> same(driver, answer(Telemetry.start()))
    "stop" -> same(driver, answer(Telemetry.stop(req.number)))
    "attach" -> attach(driver, req)
    "detach" -> same(driver, answer(Telemetry.detach(req.id)))
    "execute" -> same(driver, execute(req))
    "flood" -> same(driver, flood(req))
    "flush" -> same(driver, answer(Telemetry.flush()))
    "release" -> release(driver, req)
    "handlers" -> same(driver, read(Telemetry.handlers().join(",")))
    "enabled" -> same(driver, "ok #{Telemetry.enabled?(req.name)}")
    "dropped" -> same(driver, "ok #{Telemetry.dropped(req.id)}")
    "log" -> same(driver, read(lines(LOGS, req.id)))
    "warnings" -> same(driver, read(lines(WARNINGS, "all")))
    "idle" -> same(driver, idle())
    "stress" -> same(driver, Stress.run(req.number, req.wait))
    "starts" -> same(driver, Starts.run(req.number))
    "start_in_task" -> start_in_task(driver)
    "cancel_starter" -> cancel_starter(driver)
    "churn" -> churn(driver, req)
    "forge_failure" -> same(driver, forge(Types.HubMsg.Failed(Types.Failure(id: req.id, task: -1, kind: "forged"))))
    "forge_end" -> same(driver, forge_end(req))
    "failures_gone" -> same(driver, failures_gone(req.number))
    "detaches_at_once" -> same(driver, detaches_at_once(req.number))
    "stale_claim" -> same(driver, stale_claim())
    "busy_hub" -> same(driver, busy_hub())
    "forget_other" -> same(driver, forget_other())
    "claims" -> same(driver, claims())
    "forget_under_claim" -> same(driver, forget_under_claim())
    "flush_budget" -> same(driver, flush_budget())
    "second_hub" -> same(driver, second_hub())
    "span" -> same(driver, span(req))
    "span_stress" -> same(driver, Stress.run_spans(req.number, req.wait))
    "capture" -> start_capture(driver, req)
    "captured" -> same(driver, captured(driver, req.id))
    "capture_stop" -> capture_stop(driver, req.id)
    "capture_race" -> same(driver, Stress.run_captures(req.number))
    "capture_stress" -> same(driver, Stress.run_capture(req.number, req.wait))
    "session" -> same(driver, session(req))
    "steps" -> same(driver, "ok #{steps_of(req.name)}")
    _ -> same(driver, "unknown op #{req.op}")
  end
end

def same(driver: Driver, reply: String) -> Handled = Handled(driver: driver, reply: reply)

def answer(result: Result[Void]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> "error #{e.kind}"
  end
end

# `ok`, and what was read when there is something.
def read(text: String) -> String
  return "ok" if text == ""

  "ok #{text}"
end

def lines(table: ATS[String, List[String]], key: String) -> String
  case table.get(key)
    ok(found) -> found.join(" | ")
    error(_) -> ""
  end
end

def attach(driver: Driver, req: Request) -> Handled
  gate: Channel[Bool] = Channel.new(1)
  options = Telemetry.Options()
  if req.number != 0
    options = Telemetry.Options(capacity: req.number)
  end

  result = Telemetry.attach(req.id, req.patterns, handler(req.id, req.mode, gate), options)
  case result
    ok(_) -> Handled(driver: driver.with(gates: driver.gates.put(req.id, gate)), reply: "ok")
    error(e) -> same(driver, "error #{e.kind}")
  end
end

def handler(id: String, mode: String, gate: Channel[Bool]) -> Fn[Telemetry.Event, Result[Void]]
  case mode
    "fail" -> &failing
    "crash" -> &crashing
    "slow" -> ->(event) { slowly(id, event) }
    "flush" -> ->(_event) { flushing(id) }
    "who" -> ->(_event) { who(id) }
    "doomed" -> ->(_event) { doomed(gate) }
    "block" -> ->(event) { blocked(id, gate, event) }
    _ -> ->(event) { record(id, event) }
  end
end

def record(id: String, event: Telemetry.Event) -> Result[Void]
  _ = LOGS.push(id, "#{event.name} #{event.ints} #{event.floats} #{event.metadata}")
  ok()
end

# Records the event, then waits for `release` (which closes the gate).
def blocked(id: String, gate: Channel[Bool], event: Telemetry.Event) -> Result[Void]
  _ = record(id, event)
  _ = gate.recv(BLOCK_MS)
  ok()
end

def failing(event: Telemetry.Event) -> Result[Void]
  error("could not handle #{event.name} #{event.metadata}", kind: "handler.bad")
end

def crashing(event: Telemetry.Event) -> Result[Void]
  empty: List[Int] = []
  puts(empty[event.ints.size + 1])
  ok()
end

def release(driver: Driver, req: Request) -> Handled
  case driver.gates.get(req.id)
    some(gate) ->
      gate.close
      same(driver, "ok")
    none -> same(driver, "no handler #{req.id}")
  end
end

# The rows of the table: `int`, `float` or `meta`, a key and a value.
def execute(req: Request) -> String
  ints: Map[String, Int] = {}
  floats: Map[String, Float] = {}
  metadata: Map[String, String] = {}
  for row in req.table.drop(1)
    case row[0]
      "int" -> ints = ints.put(row[1], row[2].to_i!)
      "float" -> floats = floats.put(row[1], row[2].to_f!)
      _ -> metadata = metadata.put(row[1], row[2])
    end
  end

  Telemetry.execute(req.name, ints, floats, metadata)
  "ok"
end

def flood(req: Request) -> String
  for i in 1..req.number
    Telemetry.execute(req.name, {"i": i})
  end

  "ok"
end

# Waits for the tasks of the package to end after `stop`.
def idle() -> String
  waited = 0
  while Task.pending_count() > 0 and waited < IDLE_MS
    Task.sleep(10)
    waited += 10
  end

  return "error pending #{Task.pending_count()}" if Task.pending_count() > 0

  "ok"
end

# Handles the event after a pause, as a handler that does slow work does: it records it when it is done.
def slowly(id: String, event: Telemetry.Event) -> Result[Void]
  Task.sleep(SLOW_MS)
  record(id, event)
end

# What `flush` gives when a handler calls it.
def flushing(id: String) -> Result[Void]
  _ = LOGS.push(id, answer(Telemetry.flush(FLUSH_MS)))
  ok()
end

# Waits for the gate, and then fails: a handler that is cancelled while it waits still ends with an error.
def doomed(gate: Channel[Bool]) -> Result[Void]
  _ = gate.recv(BLOCK_MS)
  error("too late", kind: "handler.late")
end

# Attaches a handler that is cancelled at once, `number` times, and then the handler of the request. What the old
# ones tell the hub late must not touch the newest handler of the same id.
def churn(driver: Driver, req: Request) -> Handled
  gate: Channel[Bool] = Channel.new(1)
  for _i in 1..req.number
    _ = Telemetry.attach(req.id, req.patterns, doomed_handler(gate))
    Telemetry.execute(req.name)
    _ = Telemetry.detach(req.id)
  end

  attach(driver, req)
end

def doomed_handler(gate: Channel[Bool]) -> Fn[Telemetry.Event, Result[Void]] = ->(_event) { doomed(gate) }

# The hub starts in a task of its own, which holds it until the driver cancels the task.
def start_in_task(driver: Driver) -> Handled
  answered: Channel[String] = Channel.new(1)
  task = Task.spawn(&hold_hub, answered)
  reply = answered.recv(BLOCK_MS).unwrap_or("no answer")
  Handled(driver: driver.with(starter: some(task)), reply: reply)
end

def hold_hub(answered: Channel[String]) -> Void
  _ = answered.send(answer(Telemetry.start()), BLOCK_MS)
  while true
    Task.sleep(1_000)
  end
end

def cancel_starter(driver: Driver) -> Handled
  case driver.starter
    some(task) ->
      Task.cancel(task)
      same(driver, "ok")
    none -> same(driver, "no starter")
  end
end

def steps_of(name: String) -> Int
  before = System.Profile.steps()
  Telemetry.execute(name, {"n": 1})
  System.Profile.steps() - before
end

# What a handler task would tell the hub that the hub did not hear from the task itself: the hub is sent the message.
def forge(message: Types.HubMsg) -> String
  case Routes.hub()
    some(address) -> answer(Actor.cast(address, message, BLOCK_MS))
    none -> "no hub"
  end
end

# The hub is told that the task of the handler `id` returned, as it is when the handler could not send `Failed`.
def forge_end(req: Request) -> String
  task = lines(LOGS, req.id).to_i.unwrap_or(-1)
  down = TaskDown(task_id: task, reason: TaskExit.Ok, code: "", message: "", file: "", line: 0, column: 0)
  forge(Types.HubMsg.Down(down))
end

def who(id: String) -> Result[Void]
  LOGS.put(id, ["#{Task.current().id}"])
  ok()
end

# Handlers that fail on their first event are gone the moment `flush` returns, round after round.
def failures_gone(rounds: Int) -> String
  for i in 1..rounds
    id = "failing#{i}"
    attached = Telemetry.attach(id, ["fail"], &failing)
    return "the attach of #{id} gave #{answer(attached)}" if not attached.ok?

    Telemetry.execute("fail.once")
    _ = Telemetry.flush()
    return "#{id} was still attached after flush" if Telemetry.handlers().include?(id)
  end

  "ok"
end

# Once `detach` has returned no event is routed to the handler: its pattern has no route left.
def detaches_at_once(rounds: Int) -> String
  for i in 1..rounds
    id = "detached#{i}"
    _ = Telemetry.attach(id, ["gone"], ->(event) { record(id, event) })
    _ = Telemetry.detach(id)
    return "#{id} still has a route after detach" if Telemetry.enabled?("gone.once")
    return "#{id} is still listed after detach" if Telemetry.handlers().include?(id)
  end

  "ok"
end

# What a start that was cancelled while it held the claim leaves behind: a claim whose time has passed.
def stale_claim() -> String
  Routes.STARTING.put(Routes.LOCK_KEY, Time.monotonic_ms - 5)
  "ok"
end

# A hub that never answers, as one that is busy in its handler: it is alive, so `start` says so, in about the time of a
# ping, and the hub stays registered.
def busy_hub() -> String
  silent: Channel[Types.HubMsg] = Channel.new(4)
  Routes.HUB.put(Routes.HUB_KEY, silent.address)
  began = Time.monotonic_ms
  started = answer(Telemetry.start())
  took = Time.monotonic_ms - began
  kept = registered(silent.address)
  Routes.HUB.delete(Routes.HUB_KEY)
  silent.close
  return "start gave #{started}, not error telemetry.started" if started != "error telemetry.started"
  return "start took #{took} ms" if took > BUSY_MAX_MS
  return "the busy hub was forgotten" if not kept

  "ok"
end

# The end of an old hub does not clear the tables of a newer one.
def forget_other() -> String
  old: Channel[Types.HubMsg] = Channel.new(1)
  current: Channel[Types.HubMsg] = Channel.new(1)
  handler: Channel[Types.Msg] = Channel.new(1)
  Routes.HUB.put(Routes.HUB_KEY, current.address)
  Routes.HANDLERS.put("kept", handler.address)
  Routes.forget_hub(old.address)
  kept = registered(current.address) and Routes.HANDLERS.has_key?("kept")
  Routes.forget_hub(current.address)
  cleared = not Routes.HANDLERS.has_key?("kept") and Routes.hub().none?
  old.close
  current.close
  handler.close
  return "the old hub cleared the newer one" if not kept
  return "the hub itself was not cleared" if not cleared

  "ok"
end

def registered(address: Address[Types.HubMsg]) -> Bool
  case Routes.hub()
    some(found) -> found == address
    none -> false
  end
end

# A claim that ran out and was taken over: the first holder's release must not delete the new holder's claim, and a
# third task cannot take the claim while it is held.
def claims() -> String
  Routes.STARTING.clear()
  first = Routes.claim()
  return "no first claim" if first.none?

  # The claims are told apart by their time, which is 1.5 s apart when one runs out for real.
  Task.sleep(5)
  Routes.STARTING.put(Routes.LOCK_KEY, Time.monotonic_ms - 1)
  second = Routes.claim()
  return "the claim that ran out was not taken over" if second.none?

  Routes.release(first.unwrap!)
  return "the first holder deleted the claim of the second" if not Routes.STARTING.has_key?(Routes.LOCK_KEY)
  return "a claim that is held was given twice" if Routes.claim().some?

  Routes.release(second.unwrap!)
  return "the claim was not released" if Routes.STARTING.has_key?(Routes.LOCK_KEY)

  "ok"
end

# While another task holds the claim (a start is running), the end of a hub is not reported to the tables: that start
# finds the hub gone by itself. Without the claim in hand it is.
def forget_under_claim() -> String
  Routes.STARTING.clear()
  old: Channel[Types.HubMsg] = Channel.new(1)
  handler: Channel[Types.Msg] = Channel.new(1)
  Routes.HUB.put(Routes.HUB_KEY, old.address)
  Routes.HANDLERS.put("kept", handler.address)
  held = Routes.claim()
  Routes.forget_hub(old.address)
  kept = registered(old.address) and Routes.HANDLERS.has_key?("kept")
  Routes.release(held.unwrap_or(0))
  Routes.forget_hub(old.address)
  cleared = Routes.hub().none? and not Routes.HANDLERS.has_key?("kept")
  old.close
  handler.close
  return "the tables were cleared while a start held the claim" if not kept
  return "the tables were not cleared" if not cleared

  "ok"
end

# `flush` keeps to its time even when the hub does not answer: the ping and the barriers share the budget.
def flush_budget() -> String
  silent_hub: Channel[Types.HubMsg] = Channel.new(4)
  silent_handler: Channel[Types.Msg] = Channel.new(4)
  Routes.HUB.put(Routes.HUB_KEY, silent_hub.address)
  Routes.HANDLERS.put("silent", silent_handler.address)
  began = Time.monotonic_ms
  flushed = answer(Telemetry.flush(FLUSH_BUDGET_MS))
  took = Time.monotonic_ms - began
  Routes.clear()
  Routes.HUB.clear()
  silent_hub.close
  silent_handler.close
  return "flush gave #{flushed}, not error telemetry.timeout" if flushed != "error telemetry.timeout"
  return "flush of #{FLUSH_BUDGET_MS} ms took #{took} ms" if took > FLUSH_BUDGET_MS + FLUSH_SLACK_MS

  "ok"
end

# Two hubs are begun, as two tasks that both hold the claim would: the second finds the first registered, stops its
# actor, and no task is left over.
def second_hub() -> String
  before = Task.pending_count()
  first = answer(Hub.begin())
  second = answer(Hub.begin())
  waited = 0
  while Task.pending_count() > before + 1 and waited < IDLE_MS
    Task.sleep(5)
    waited += 5
  end

  extra = Task.pending_count() - before
  return "the first hub gave #{first}" if first != "ok"
  return "the second hub gave #{second}, not error telemetry.started" if second != "error telemetry.started"
  return "#{extra} tasks run, not one hub" if extra != 1

  "ok"
end

# Runs a span whose body does what `mode` says: `ok` gives 42, `error` gives an error of the kind `span.bad`, `crash`
# crashes (in a task of its own, which the driver awaits). The body waits `number` ms first.
def span(req: Request) -> String
  metadata: Map[String, String] = {}
  for row in req.table.drop(1)
    metadata = metadata.put(row[1], row[2])
  end

  return spanned(Task.await(Task.spawn(&crashing_span, req.name))) if req.mode == "crash"

  spanned(Telemetry.span(req.name, metadata, -> { work(req.mode, req.number) }))
end

def spanned(result: Result[Int]) -> String
  case result
    ok(value) -> "ok #{value}"
    error(e) -> "error #{e.kind}"
  end
end

def work(mode: String, sleep_ms: Int) -> Result[Int]
  Task.sleep(sleep_ms)
  return error("the body failed", kind: "span.bad") if mode == "error"

  ok(42)
end

def crashing_span(name: String) -> Result[Int] = Telemetry.span(name, {}, -> { crashing_body() })

def crashing_body() -> Result[Int]
  empty: List[Int] = []
  ok(empty[1])
end

# A capture of the testing helper, kept under the name `id` of the request.
def start_capture(driver: Driver, req: Request) -> Handled
  room = Testing.ROOM
  if req.number != 0
    room = req.number
  end

  case Testing.capture(req.patterns, room)
    ok(made) -> Handled(driver: driver.with(captures: driver.captures.put(req.id, made)), reply: "ok")
    error(e) -> same(driver, "error #{e.kind}")
  end
end

def captured(driver: Driver, id: String) -> String
  case driver.captures.get(id)
    some(made) -> names(Testing.events(made))
    none -> "no capture #{id}"
  end
end

def names(result: Result[List[Telemetry.Event]]) -> String
  case result
    ok(found) -> read(found.map(->(event) { event.name }).join(", "))
    error(e) -> "error #{e.kind}"
  end
end

def capture_stop(driver: Driver, id: String) -> Handled
  case driver.captures.get(id)
    some(made) -> same(driver, answer(Testing.stop(made)))
    none -> same(driver, "no capture #{id}")
  end
end

# A session in the driver, whose hub runs: the session uses it and leaves it running, with no handler of its own.
def session(req: Request) -> String
  result = Testing.session(req.patterns, ->(made) { emit_and_read(made, req.name) })
  left = Telemetry.handlers()
  return "the session left the handlers #{left}" if not left.empty?

  names(result)
end

def emit_and_read(made: Testing.Capture, name: String) -> Result[List[Telemetry.Event]]
  Telemetry.execute(name)
  Testing.events(made)
end

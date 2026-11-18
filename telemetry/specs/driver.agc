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
import {Acts, Body, Churn, Emit, Flood, Handler, Request, Session, SpanRun, Watch} from "protocol"

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
  case req
    Request.Start -> same(driver, answer(Telemetry.start()))
    Request.Stop(timeout_ms) -> same(driver, answer(Telemetry.stop(timeout_ms)))
    Request.Attach(spec) -> attach(driver, spec)
    Request.Detach(id) -> same(driver, answer(Telemetry.detach(id)))
    Request.Execute(emit) -> same(driver, execute(emit))
    Request.Flood(spec) -> same(driver, flood(spec))
    Request.Flush -> same(driver, answer(Telemetry.flush()))
    Request.Release(id) -> release(driver, id)
    Request.Handlers -> same(driver, read(Telemetry.handlers().join(",")))
    Request.Enabled(name) -> same(driver, "ok #{Telemetry.enabled?(name)}")
    Request.Dropped(id) -> same(driver, "ok #{Telemetry.dropped(id)}")
    Request.Log(id) -> same(driver, read(lines(LOGS, id)))
    Request.Warnings -> same(driver, read(lines(WARNINGS, "all")))
    Request.Idle -> same(driver, idle())
    Request.Stress(load) -> same(driver, Stress.run(load.tasks, load.events))
    Request.Starts(tasks) -> same(driver, Starts.run(tasks))
    Request.StartInTask -> start_in_task(driver)
    Request.CancelStarter -> cancel_starter(driver)
    Request.Churn(spec) -> churn(driver, spec)
    Request.ForgeFailure(id) ->
      same(driver, forge(Types.HubMsg.Failed(Types.Failure(id: id, task: -1, kind: "forged"))))
    Request.ForgeEnd(id) -> same(driver, forge_end(id))
    Request.FailuresGone(count) -> same(driver, failures_gone(count))
    Request.DetachesAtOnce(count) -> same(driver, detaches_at_once(count))
    Request.StaleClaim -> same(driver, stale_claim())
    Request.BusyHub -> same(driver, busy_hub())
    Request.ForgetOther -> same(driver, forget_other())
    Request.Claims -> same(driver, claims())
    Request.ForgetUnderClaim -> same(driver, forget_under_claim())
    Request.FlushBudget -> same(driver, flush_budget())
    Request.SecondHub -> same(driver, second_hub())
    Request.Span(run) -> same(driver, span(run))
    Request.SpanStress(load) -> same(driver, Stress.run_spans(load.tasks, load.events))
    Request.Capture(watch) -> start_capture(driver, watch)
    Request.Captured(id) -> same(driver, captured(driver, id))
    Request.CaptureStop(id) -> capture_stop(driver, id)
    Request.CaptureRace(tasks) -> same(driver, Stress.run_captures(tasks))
    Request.CaptureStress(load) -> same(driver, Stress.run_capture(load.tasks, load.events))
    Request.Session(spec) -> same(driver, session(spec))
    Request.Steps(name) -> same(driver, "ok #{steps_of(name)}")
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

def attach(driver: Driver, spec: Handler) -> Handled
  gate: Channel[Bool] = Channel.new(1)
  options = Telemetry.Options()
  if spec.capacity != 0
    options = Telemetry.Options(capacity: spec.capacity)
  end

  result = Telemetry.attach(spec.id, spec.patterns, handler(spec.id, spec.acts, gate), options)
  case result
    ok(_) -> Handled(driver: driver.with(gates: driver.gates.put(spec.id, gate)), reply: "ok")
    error(e) -> same(driver, "error #{e.kind}")
  end
end

def handler(id: String, acts: Acts, gate: Channel[Bool]) -> Fn[Telemetry.Event, Result[Void]]
  case acts
    Acts.Fail -> &failing
    Acts.Crash -> &crashing
    Acts.Slow -> ->(event) { slowly(id, event) }
    Acts.Flush -> ->(_event) { flushing(id) }
    Acts.Who -> ->(_event) { who(id) }
    Acts.Block -> ->(event) { blocked(id, gate, event) }
    Acts.Record -> ->(event) { record(id, event) }
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

def release(driver: Driver, id: String) -> Handled
  case driver.gates.get(id)
    some(gate) ->
      gate.close
      same(driver, "ok")
    none -> same(driver, "no handler #{id}")
  end
end

# The rows of the table: `int`, `float` or `meta`, a key and a value.
def execute(emit: Emit) -> String
  ints: Map[String, Int] = {}
  floats: Map[String, Float] = {}
  metadata: Map[String, String] = {}
  for row in emit.table.drop(1)
    case row[0]
      "int" -> ints = ints.put(row[1], row[2].to_i!)
      "float" -> floats = floats.put(row[1], row[2].to_f!)
      _ -> metadata = metadata.put(row[1], row[2])
    end
  end

  Telemetry.execute(emit.name, ints, floats, metadata)
  "ok"
end

def flood(spec: Flood) -> String
  for i in 1..spec.count
    Telemetry.execute(spec.name, {"i": i})
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

# Attaches a handler that is cancelled at once, `count` times, and then the handler of the request, whose queue has
# room for `count` events, as the step gives it. What the old ones tell the hub late must not touch the newest handler
# of the same id.
def churn(driver: Driver, spec: Churn) -> Handled
  gate: Channel[Bool] = Channel.new(1)
  for _i in 1..spec.count
    _ = Telemetry.attach(spec.handler.id, spec.handler.patterns, doomed_handler(gate))
    Telemetry.execute(spec.name)
    _ = Telemetry.detach(spec.handler.id)
  end

  attach(driver, spec.handler)
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
def forge_end(id: String) -> String
  task = lines(LOGS, id).to_i.unwrap_or(-1)
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

# Runs a span whose body does what `body` says: `Returns` gives 42, `Fails` gives an error of the kind `span.bad`,
# `Crashes` crashes (in a task of its own, which the driver awaits). The body waits `sleep_ms` ms first.
def span(run: SpanRun) -> String
  metadata: Map[String, String] = {}
  for row in run.table.drop(1)
    metadata = metadata.put(row[1], row[2])
  end

  case run.body
    Body.Crashes -> spanned(Task.await(Task.spawn(&crashing_span, run.name)))
    Body.Fails -> spanned(Telemetry.span(run.name, metadata, -> { work(true, run.sleep_ms) }))
    Body.Returns -> spanned(Telemetry.span(run.name, metadata, -> { work(false, run.sleep_ms) }))
  end
end

def spanned(result: Result[Int]) -> String
  case result
    ok(value) -> "ok #{value}"
    error(e) -> "error #{e.kind}"
  end
end

def work(fails: Bool, sleep_ms: Int) -> Result[Int]
  Task.sleep(sleep_ms)
  return error("the body failed", kind: "span.bad") if fails

  ok(42)
end

def crashing_span(name: String) -> Result[Int] = Telemetry.span(name, {}, -> { crashing_body() })

def crashing_body() -> Result[Int]
  empty: List[Int] = []
  ok(empty[1])
end

# A capture of the testing helper, kept under the name `id` of the request.
def start_capture(driver: Driver, watch: Watch) -> Handled
  room = Testing.ROOM
  if watch.room != 0
    room = watch.room
  end

  case Testing.capture(watch.patterns, room)
    ok(made) -> Handled(driver: driver.with(captures: driver.captures.put(watch.id, made)), reply: "ok")
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
def session(spec: Session) -> String
  result = Testing.session(spec.patterns, ->(made) { emit_and_read(made, spec.name) })
  left = Telemetry.handlers()
  return "the session left the handlers #{left}" if not left.empty?

  names(result)
end

def emit_and_read(made: Testing.Capture, name: String) -> Result[List[Telemetry.Event]]
  Telemetry.execute(name)
  Testing.events(made)
end

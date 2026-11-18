## The program under test of the features: it holds the hub and the handlers that the steps attached, and runs the
## requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## Replies: `ok`, `ok TEXT` (a read) and `error KIND` for a failed call. A handler records the events it gets in a
## table of this program, which a step reads after `flush`.

import Logger from "std/logger"
import Stress from "stress"
import Telemetry from "../telemetry"
import {Request} from "protocol"

private

# What the Logger got at warning level, and what each handler recorded.
WARNINGS: ATS[String, List[String]] = ATS.new()
LOGS: ATS[String, List[String]] = ATS.new()
IDLE_MS = 2_000
BLOCK_MS = 60_000

struct Driver
  gates: Map[String, Channel[Bool]]
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
    ok(_) -> Handled(driver: Driver(gates: driver.gates.put(req.id, gate)), reply: "ok")
    error(e) -> same(driver, "error #{e.kind}")
  end
end

def handler(id: String, mode: String, gate: Channel[Bool]) -> Fn[Telemetry.Event, Result[Void]]
  case mode
    "fail" -> &failing
    "crash" -> &crashing
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

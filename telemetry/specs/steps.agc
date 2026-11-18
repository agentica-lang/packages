## The steps of the features. They drive the hub through `driver.agc`, which holds it with its handlers (see
## `protocol.agc`): a step cannot keep the tasks of the package running between steps.

import BDD from "std/bdd"
import Regex from "std/regex"
import Conformance from "../conformance"
import Telemetry from "../telemetry"
import Testing from "../testing"
import Types from "../src/types"
import {Acts, Body, Churn, Emit, Flood, Handler, Load, Request, Session, SpanRun, Watch} from "protocol"

private

REPLY_MS = 60_000
REPLY = "reply"
STOP_MS = 5_000
SPAN_ID = /"span_id": "([0-9]+)"/
DURATION = /"duration_ns": ([0-9]+)/

def main() -> Void
  BDD.run([
    BDD.step("the hub is started") do |ctx, _args| ask(ctx, Request.Start) end,
    BDD.step("I stop the hub") do |ctx, _args| ask(ctx, Request.Stop(STOP_MS)) end,
    BDD.step("I attach {string} to {string}") do |ctx, args| attach(ctx, args, Acts.Record, 0) end,
    BDD.step("I attach {string} to {string} with a queue of {int}") do |ctx, args|
      attach(ctx, args, Acts.Record, args[2].to_i!)
    end,
    BDD.step("I attach {string} to {string} and it fails") do |ctx, args| attach(ctx, args, Acts.Fail, 0) end,
    BDD.step("I attach {string} to {string} and it crashes") do |ctx, args| attach(ctx, args, Acts.Crash, 0) end,
    BDD.step("I attach {string} to {string} and it is slow") do |ctx, args| attach(ctx, args, Acts.Slow, 0) end,
    BDD.step("I attach {string} to {string} and it tells its task") do |ctx, args| attach(ctx, args, Acts.Who, 0) end,
    BDD.step("the hub is told that an older handler {string} failed") do |ctx, args|
      ask(ctx, Request.ForgeFailure(args[0]))
    end,
    BDD.step("the hub is told that the task of {string} returned") do |ctx, args|
      ask(ctx, Request.ForgeEnd(args[0]))
    end,
    BDD.step("I attach {string} to {string} and it flushes") do |ctx, args| attach(ctx, args, Acts.Flush, 0) end,
    BDD.step("I attach {string} to {string} and it blocks, with a queue of {int}") do |ctx, args|
      attach(ctx, args, Acts.Block, args[2].to_i!)
    end,
    BDD.step("the hub is started by a task of its own") do |ctx, _args| ask(ctx, Request.StartInTask) end,
    BDD.step("that task is cancelled") do |ctx, _args| ask(ctx, Request.CancelStarter) end,
    BDD.step("{int} tasks start the hub at once") do |ctx, args| ask(ctx, Request.Starts(args[0].to_i!)) end,
    BDD.step(
      "I attach {string} to {string} {int} times, cancel it at once each time, and attach it again",
    ) do |ctx, args|
      ask(
        ctx,
        Request.Churn(
          Churn(
            handler: Handler(id: args[0], patterns: args[1].split(","), capacity: args[2].to_i!),
            name: "churn.start",
            count: args[2].to_i!,
          ),
        ),
      )
    end,
    BDD.step("{int} handlers fail one after the other, each on its first event") do |ctx, args|
      ask(ctx, Request.FailuresGone(args[0].to_i!))
    end,
    BDD.step("{int} handlers are attached and detached one after the other") do |ctx, args|
      ask(ctx, Request.DetachesAtOnce(args[0].to_i!))
    end,
    BDD.step("a start that was cancelled left its claim behind") do |ctx, _args| ask(ctx, Request.StaleClaim) end,
    BDD.step("a hub that does not answer is registered and the hub is started") do |ctx, _args|
      ask(ctx, Request.BusyHub)
    end,
    BDD.step("the end of an old hub is reported while a newer one is registered") do |ctx, _args|
      ask(ctx, Request.ForgetOther)
    end,
    BDD.step("claims are taken, run out and are given back") do |ctx, _args| ask(ctx, Request.Claims) end,
    BDD.step("the end of a hub is reported while a start holds the claim") do |ctx, _args|
      ask(ctx, Request.ForgetUnderClaim)
    end,
    BDD.step("a flush of 300 ms meets a hub and a handler that do not answer") do |ctx, _args|
      ask(ctx, Request.FlushBudget)
    end,
    BDD.step("two hubs are begun, as two tasks that both hold the claim would") do |ctx, _args|
      ask(ctx, Request.SecondHub)
    end,
    BDD.step("I run a span {string}") do |ctx, args| run_span(ctx, args[0], Body.Returns, 0, []) end,
    BDD.step("I run a span {string} that sleeps {int} ms") do |ctx, args|
      run_span(ctx, args[0], Body.Returns, args[1].to_i!, [])
    end,
    BDD.step("I run a span {string} whose body returns an error") do |ctx, args|
      run_span(ctx, args[0], Body.Fails, 0, [])
    end,
    BDD.step("I run a span {string} whose body crashes") do |ctx, args|
      run_span(ctx, args[0], Body.Crashes, 0, [])
    end,
    BDD.step("I run a span {string} with:") do |ctx, args| run_span(ctx, args[0], Body.Returns, 0, BDD.table(ctx)) end,
    BDD.step("the handler {string} got events with one span_id") do |ctx, args| expect_one_span(ctx, args[0]) end,
    BDD.step("the handler {string} got {int} span_ids") do |ctx, args|
      expect_span_ids(ctx, args[0], args[1].to_i!)
    end,
    BDD.step("the last event of {string} has a duration") do |ctx, args| expect_duration(ctx, args[0], 0, true) end,
    BDD.step("the last event of {string} has a duration of at least {int} ms") do |ctx, args|
      expect_duration(ctx, args[0], args[1].to_i!, true)
    end,
    BDD.step("the first event of {string} has no duration") do |ctx, args| expect_duration(ctx, args[0], 0, false) end,
    BDD.step("the last event of {string} includes:") do |ctx, args|
      expect_includes(ctx, args[0], BDD.doc_string(ctx), true)
    end,
    BDD.step("the first event of {string} includes:") do |ctx, args|
      expect_includes(ctx, args[0], BDD.doc_string(ctx), false)
    end,
    BDD.step("I check the event {string}") do |ctx, args| check_event(ctx, args[0], []) end,
    BDD.step("I check the event {string} with:") do |ctx, args| check_event(ctx, args[0], BDD.table(ctx)) end,
    BDD.step("{int} tasks run {int} spans each at once") do |ctx, args|
      ask(ctx, Request.SpanStress(Load(tasks: args[0].to_i!, events: args[1].to_i!)))
    end,
    BDD.step("I capture {string} as {string}") do |ctx, args| capture(ctx, args, 0) end,
    BDD.step("I capture {string} as {string} with room for {int} events") do |ctx, args|
      capture(ctx, args, args[2].to_i!)
    end,
    BDD.step("I read the events of the capture {string}") do |ctx, args| ask(ctx, Request.Captured(args[0])) end,
    BDD.step("I stop the capture {string}") do |ctx, args| ask(ctx, Request.CaptureStop(args[0])) end,
    BDD.step("{int} tasks emit {int} events each, into a capture") do |ctx, args|
      ask(ctx, Request.CaptureStress(Load(tasks: args[0].to_i!, events: args[1].to_i!)))
    end,
    BDD.step("{int} tasks capture at once") do |ctx, args| ask(ctx, Request.CaptureRace(args[0].to_i!)) end,
    BDD.step("the driver runs a session that captures {string} and emits {string}") do |ctx, args|
      ask(ctx, Request.Session(Session(patterns: args[0].split(","), name: args[1])))
    end,
    BDD.step("a session in this step captures {string} and emits {string}") do |ctx, args|
      session_in_step(ctx, args[0], args[1])
    end,
    BDD.step("I measure the steps of emitting {string}") do |ctx, args| ask(ctx, Request.Steps(args[0])) end,
    BDD.step("I detach {string}") do |ctx, args| ask(ctx, Request.Detach(args[0])) end,
    BDD.step("I release {string}") do |ctx, args| ask(ctx, Request.Release(args[0])) end,
    BDD.step("I emit {string}") do |ctx, args| ask(ctx, Request.Execute(Emit(name: args[0]))) end,
    BDD.step("I emit {string} with:") do |ctx, args|
      ask(ctx, Request.Execute(Emit(name: args[0], table: BDD.table(ctx))))
    end,
    BDD.step("I emit {int} events {string}") do |ctx, args|
      ask(ctx, Request.Flood(Flood(name: args[1], count: args[0].to_i!)))
    end,
    BDD.step("I flush") do |ctx, _args| ask(ctx, Request.Flush) end,
    BDD.step("I ask for the handlers") do |ctx, _args| ask(ctx, Request.Handlers) end,
    BDD.step("I ask whether {string} is enabled") do |ctx, args| ask(ctx, Request.Enabled(args[0])) end,
    BDD.step("I wait for the tasks of the hub to end") do |ctx, _args| ask(ctx, Request.Idle) end,
    BDD.step(
      "{int} tasks attach, emit {int} events each and detach, while one handler hears everything",
    ) do |ctx, args| ask(ctx, Request.Stress(Load(tasks: args[0].to_i!, events: args[1].to_i!))) end,
    BDD.step("the reply is {string}") do |ctx, args| expect_reply(ctx, args[0]) end,
    BDD.step("the reply is a number up to {int}") do |ctx, args| expect_up_to(ctx, args[0].to_i!) end,
    BDD.step("the Logger got nothing") do |ctx, _args| expect_warnings(ctx, "") end,
    BDD.step("the handler {string} got the events {string}") do |ctx, args| expect_names(ctx, args[0], args[1]) end,
    BDD.step("the handler {string} got:") do |ctx, args| expect_log(ctx, args[0], BDD.doc_string(ctx)) end,
    BDD.step("the handler {string} got between {int} and {int} events") do |ctx, args|
      expect_got_between(ctx, args[0], args[1].to_i!, args[2].to_i!)
    end,
    BDD.step("the handler {string} got and dropped {int} events in all") do |ctx, args|
      expect_all(ctx, args[0], args[1].to_i!)
    end,
    BDD.step("the handler {string} dropped between {int} and {int} events") do |ctx, args|
      expect_dropped_between(ctx, args[0], args[1].to_i!, args[2].to_i!)
    end,
    BDD.step("the Logger got:") do |ctx, _args| expect_warnings(ctx, BDD.doc_string(ctx)) end,
    BDD.step("no warning includes {string}") do |ctx, args| expect_clean(ctx, args[0]) end,
  ])
end

def attach(ctx: BDD.Context, args: List[String], acts: Acts, capacity: Int) -> BDD.Context
  ask(ctx, Request.Attach(Handler(id: args[0], patterns: args[1].split(","), acts: acts, capacity: capacity)))
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end

# Sends the request to the driver, started on the first one, and keeps its reply line for the `Then` steps.
def ask(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  BDD.set(asked, REPLY, JSON.from(BDD.read_line(asked, REPLY_MS).unwrap_or("no reply from the driver")))
end

def reply(ctx: BDD.Context) -> String = JSON.string(BDD.get(ctx, REPLY).unwrap!).unwrap_or("")

def expect_reply(ctx: BDD.Context, want: String) -> BDD.Context
  got = reply(ctx)
  BDD.assert(ctx, got == want, "the reply is #{got}, and should be #{want}")
end

def expect_up_to(ctx: BDD.Context, limit: Int) -> BDD.Context
  steps = count(ctx)
  BDD.assert(ctx, steps <= limit, "#{steps} is more than #{limit}")
end

# What the reply `ok A | B` of a read holds: the items A and B.
def items(reply: String) -> List[String]
  text = reply.replace("ok ", "")
  return [] if reply == "ok" or text == ""

  text.split(" | ")
end

# Asks for what the handler recorded, as the driver wrote it, one text per event: the context holds the answer.
def read_log(ctx: BDD.Context, id: String) -> BDD.Context = ask(ctx, Request.Log(id))

def read_dropped(ctx: BDD.Context, id: String) -> BDD.Context = ask(ctx, Request.Dropped(id))

def count(ctx: BDD.Context) -> Int = reply(ctx).replace("ok ", "").to_i!

def expect_names(ctx: BDD.Context, id: String, want: String) -> BDD.Context
  asked = read_log(ctx, id)
  names = items(reply(asked)).map(->(line) { line.split(" ")[0] }).join(", ")
  BDD.assert(asked, names == want, "the handler got [#{names}], and should get [#{want}]")
end

def expect_log(ctx: BDD.Context, id: String, want: String) -> BDD.Context
  asked = read_log(ctx, id)
  got = items(reply(asked)).join("\n")
  BDD.assert(asked, got == want.strip, "the handler got:\n#{got}\nand should get:\n#{want}")
end

def between(ctx: BDD.Context, count: Int, low: Int, high: Int) -> BDD.Context
  BDD.assert(ctx, count >= low and count <= high, "#{count} is not between #{low} and #{high}")
end

def expect_got_between(ctx: BDD.Context, id: String, low: Int, high: Int) -> BDD.Context
  asked = read_log(ctx, id)
  between(asked, items(reply(asked)).size, low, high)
end

def expect_dropped_between(ctx: BDD.Context, id: String, low: Int, high: Int) -> BDD.Context
  asked = read_dropped(ctx, id)
  between(asked, count(asked), low, high)
end

def expect_all(ctx: BDD.Context, id: String, total: Int) -> BDD.Context
  logged = read_log(ctx, id)
  got = items(reply(logged)).size
  asked = read_dropped(logged, id)
  lost = count(asked)
  BDD.assert(asked, got + lost == total, "the handler got #{got} and dropped #{lost}, and should add up to #{total}")
end

def expect_warnings(ctx: BDD.Context, want: String) -> BDD.Context
  asked = ask(ctx, Request.Warnings)
  got = items(reply(asked)).join("\n")
  BDD.assert(asked, got == want.strip, "the Logger got:\n#{got}\nand should get:\n#{want}")
end

def expect_clean(ctx: BDD.Context, text: String) -> BDD.Context
  asked = ask(ctx, Request.Warnings)
  found = items(reply(asked)).select(->(line) { line.include?(text) })
  BDD.assert(asked, found.empty?, "a warning includes #{text}: #{found}")
end

def run_span(ctx: BDD.Context, name: String, body: Body, sleep_ms: Int, table: List[List[String]]) -> BDD.Context
  ask(ctx, Request.Span(SpanRun(name: name, body: body, sleep_ms: sleep_ms, table: table)))
end

# The events of the handler as the driver wrote them, one text each.
def logged(ctx: BDD.Context, id: String) -> BDD.Context = read_log(ctx, id)

# The first group of the regex in the line, or "" when it does not match.
def group(line: String, regex: Regex.Regex) -> String
  case Regex.match(line, regex)
    ok(found) -> found.groups[1].text
    error(_) -> ""
  end
end

def span_ids(lines: List[String]) -> List[String] = lines.map(->(line) { group(line, SPAN_ID) })

def expect_one_span(ctx: BDD.Context, id: String) -> BDD.Context
  asked = read_log(ctx, id)
  ids = span_ids(items(reply(asked)))
  distinct = ids.uniq
  BDD.assert(asked, ids.size > 0 and distinct.size == 1 and distinct[0] != "", "the span ids are #{ids}")
end

def expect_span_ids(ctx: BDD.Context, id: String, want: Int) -> BDD.Context
  asked = read_log(ctx, id)
  distinct = span_ids(items(reply(asked))).uniq
  BDD.assert(asked, distinct.size == want, "the span ids are #{distinct}, and should be #{want}")
end

def expect_duration(ctx: BDD.Context, id: String, least_ms: Int, wanted: Bool) -> BDD.Context
  asked = read_log(ctx, id)
  lines = items(reply(asked))
  line = lines.last
  if not wanted
    line = lines.first
  end

  found = group(line, DURATION)
  return BDD.assert(asked, found == "", "the event has a duration: #{line}") if not wanted

  ns = found.to_i.unwrap_or(-1)
  BDD.assert(asked, ns >= least_ms * 1_000_000, "the duration is #{ns} ns, and should be #{least_ms} ms or more")
end

def expect_includes(ctx: BDD.Context, id: String, text: String, last: Bool) -> BDD.Context
  asked = read_log(ctx, id)
  lines = items(reply(asked))
  line = lines.first
  if last
    line = lines.last
  end

  BDD.assert(asked, line.include?(text.strip), "the event is #{line}, and should include #{text.strip}")
end

# Checks an event of the rows (`int`, `float` or `meta`, a key and a value) with the conformance helper, in the step
# itself: it is a pure function.
def check_event(ctx: BDD.Context, name: String, rows: List[List[String]]) -> BDD.Context
  ints: Map[String, Int] = {}
  floats: Map[String, Float] = {}
  metadata: Map[String, String] = {}
  for row in rows.drop(1)
    case row[0]
      "int" -> ints = ints.put(row[1], row[2].to_i!)
      "float" -> floats = floats.put(row[1], row[2].to_f!)
      _ -> metadata = metadata.put(row[1], row[2])
    end
  end

  checked = Conformance.check(Types.Event(name: name, ints: ints, floats: floats, metadata: metadata))
  text = "ok"
  case checked
    ok(_) -> nil
    error(e) -> text = "error #{e.kind}"
  end

  BDD.set(ctx, REPLY, JSON.from(text))
end

def capture(ctx: BDD.Context, args: List[String], room: Int) -> BDD.Context
  ask(ctx, Request.Capture(Watch(id: args[1], patterns: args[0].split(","), room: room)))
end

# The whole helper in the step itself: it starts the hub, captures, reads, and ends everything, so the step leaves no
# task running (the scenario fails with RUNTIME-BDD-PENDING-TASKS otherwise).
def session_in_step(ctx: BDD.Context, patterns: String, name: String) -> BDD.Context
  result = Testing.session(patterns.split(","), ->(made) { emit_and_read(made, name) })
  text = "ok"
  case result
    ok(found) -> text = "ok #{found.map(->(event) { event.name }).join(", ")}"
    error(e) -> text = "error #{e.kind}"
  end

  BDD.set(ctx, REPLY, JSON.from(text))
end

def emit_and_read(made: Testing.Capture, name: String) -> Result[List[Telemetry.Event]]
  Telemetry.execute(name)
  Testing.events(made)
end

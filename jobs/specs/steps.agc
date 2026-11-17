## The steps of the features. Most of them drive the memory backend through `driver.agc`, which holds the backend and
## the clock (see `protocol.agc`): a step cannot keep the backend's actor between steps. The steps of the conformance
## suite run it in the step itself, since a case makes its own backend and ends it.

import BDD from "std/bdd"
import Conformance from "../conformance"
import Jobs from "../jobs"
import Model from "model"
import {Request} from "protocol"

private

REPLY_MS = 60_000
LEASE_MS = 30_000
OUTCOMES = "outcomes"
REPLY = "reply"
HEADER = [["setting", "value"]]

def main() -> Void
  BDD.run([
    BDD.step("a memory backend on a manual clock") do |ctx, _args| ask(ctx, Request(op: "start", table: HEADER)) end,
    BDD.step("a memory backend on a manual clock with:") do |ctx, _args|
      ask(ctx, Request(op: "start", table: BDD.table(ctx)))
    end,
    BDD.step("a memory backend on the wall clock") do |ctx, _args|
      ask(ctx, Request(op: "start", table: [["setting", "value"], ["clock", "wall"]]))
    end,
    BDD.step("I enqueue {string} into {string}") do |ctx, args|
      ask(ctx, Request(op: "enqueue", text: args[0], queue: args[1], table: HEADER))
    end,
    BDD.step("I enqueue {string} into {string} with:") do |ctx, args|
      ask(ctx, Request(op: "enqueue", text: args[0], queue: args[1], table: BDD.table(ctx)))
    end,
    BDD.step("I enqueue the jobs {string} into {string} in one batch") do |ctx, args|
      ask(ctx, Request(op: "enqueue_all", text: args[0], queue: args[1]))
    end,
    BDD.step("I fetch a job of {string} as {string}") do |ctx, args|
      ask(ctx, Request(op: "fetch", queue: args[0], name: args[1], number: LEASE_MS))
    end,
    BDD.step("I fetch a job of {string} as {string}, leased for {int} ms") do |ctx, args|
      ask(ctx, Request(op: "fetch", queue: args[0], name: args[1], number: args[2].to_i!))
    end,
    BDD.step("I fetch {int} jobs of {string} as {string}") do |ctx, args|
      ask(ctx, Request(op: "fetch", queue: args[1], name: args[2], number: LEASE_MS, max: args[0].to_i!))
    end,
    BDD.step("I ack {string}") do |ctx, args| ask(ctx, Request(op: "ack", name: args[0])) end,
    BDD.step("I retry {string} in {int} ms") do |ctx, args|
      ask(ctx, Request(op: "retry", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("I retry {string} in {int} ms, with the error {string}") do |ctx, args|
      ask(ctx, Request(op: "retry", name: args[0], number: args[1].to_i!, text: args[2]))
    end,
    BDD.step("I release {string}") do |ctx, args| ask(ctx, Request(op: "release", name: args[0])) end,
    BDD.step("I kill {string}") do |ctx, args| ask(ctx, Request(op: "kill", name: args[0])) end,
    BDD.step("I extend {string} by {int} ms") do |ctx, args|
      ask(ctx, Request(op: "extend", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("the clock moves {int} ms") do |ctx, args| ask(ctx, Request(op: "advance", number: args[0].to_i!)) end,
    BDD.step("I ask for the counts of {string}") do |ctx, args| ask(ctx, Request(op: "counts", queue: args[0])) end,
    BDD.step("I close the backend") do |ctx, _args| ask(ctx, Request(op: "close", number: 1_000)) end,
    BDD.step("a fetch of {string} starts to wait as {string}") do |ctx, args|
      ask(ctx, Request(op: "wait", queue: args[0], name: args[1]))
    end,
    BDD.step("a fetch of {string} starts to wait as {string} for {int} ms") do |ctx, args|
      ask(ctx, Request(op: "wait", queue: args[0], name: args[1], number: args[2].to_i!))
    end,
    BDD.step("the fetch {string} ends") do |ctx, args| ask(ctx, Request(op: "wait_end", name: args[0])) end,
    BDD.step("the clock moves {int} ms at a time until the fetch {string} ends") do |ctx, args|
      ask(ctx, Request(op: "wait_end", name: args[1], number: args[0].to_i!))
    end,
    BDD.step("I drain {string}") do |ctx, args| ask(ctx, Request(op: "drain", queue: args[0], kind: "ready")) end,
    BDD.step("I drain {string}, at most {int} jobs") do |ctx, args|
      ask(ctx, Request(op: "drain", queue: args[0], kind: "ready", number: args[1].to_i!))
    end,
    BDD.step("I drain {string}, with the jobs that wait for a time, and no clock") do |ctx, args|
      ask(ctx, Request(op: "drain", queue: args[0], kind: "all without clock"))
    end,
    BDD.step("I drain {string}, with the jobs that wait for a time") do |ctx, args|
      ask(ctx, Request(op: "drain", queue: args[0], kind: "all"))
    end,
    BDD.step("{int} consumers work off {int} jobs of one queue while producers add them") do |ctx, args|
      ask(ctx, Request(op: "stress", number: args[0].to_i!, wait: args[1].to_i!))
    end,
    BDD.step(
      "{int} consumers that wait {int} ms work off {int} jobs of one queue while producers add them",
    ) do |ctx, args|
      ask(ctx, Request(op: "stress", number: args[0].to_i!, wait_ms: args[1].to_i!, wait: args[2].to_i!))
    end,
    BDD.step("the memory backend answers like the model on {int} random calls from seed {int}") do |ctx, args|
      agree_with_model(ctx, args[0].to_i!, args[1].to_i!)
    end,
    BDD.step("the reply is {string}") do |ctx, args| expect_reply(ctx, args[0]) end,
    BDD.step("the suite runs on the memory backend") do |ctx, _args| run_suite(ctx, &memory) end,
    BDD.step("the suite runs on a memory backend whose ack never fails") do |ctx, _args|
      run_suite(ctx, &lenient_acks)
    end,
    BDD.step("the case {string} passes on a memory backend that reads the real clock") do |ctx, args|
      real_clock_case(ctx, args[0])
    end,
    BDD.step("the suite has {int} cases") do |ctx, args| expect_cases(ctx, args[0].to_i!) end,
    BDD.step("no case failed") do |ctx, _args| expect_no_failure(ctx) end,
    BDD.step("the case {string} passed") do |ctx, args| expect_status(ctx, args[0], "passed") end,
    BDD.step("the case {string} failed") do |ctx, args| expect_status(ctx, args[0], "failed") end,
  ])
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

def expect_reply(ctx: BDD.Context, want: String) -> BDD.Context
  reply = JSON.string(BDD.get(ctx, REPLY).unwrap!).unwrap_or("")
  BDD.assert(ctx, reply == want, "the reply is #{reply}, and should be #{want}")
end

def memory(clock: Fn[Int]) -> Result[Jobs.Backend] = Jobs.memory(Jobs.MemoryOptions(clock: some(clock)))

def lenient_acks(clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try memory(clock)
  ok(backend.with(ack: ->(_lease) { ok() }))
end

# A memory backend that ignores the clock it is given and reads the wall clock, as a database does.
def real_clock(_clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try Jobs.memory()
  ok(backend.with(caps: Jobs.Caps(has_clock: false)))
end

def real_clock_case(ctx: BDD.Context, name: String) -> BDD.Context
  result = Conformance.run(name, &real_clock)
  BDD.assert(ctx, result.ok?, "the case #{name} on the real clock: #{result}")
end

# The outcomes are kept as lines: `passed` or `failed`, a tab, the name of the case.
def run_suite(ctx: BDD.Context, make: Conformance.Maker) -> BDD.Context
  lines = Conformance.run_all(make).map(->(outcome) { "#{status_word(outcome.status)}\t#{outcome.name}" })
  BDD.set(ctx, OUTCOMES, JSON.from(lines))
end

def status_word(status: Conformance.Status) -> String
  case status
    Conformance.Status.Passed -> "passed"
    Conformance.Status.Failed(_) -> "failed"
  end
end

def outcomes(ctx: BDD.Context) -> List[String]
  JSON.decode(BDD.get(ctx, OUTCOMES).unwrap!, List[String]).unwrap_or([])
end

def expect_cases(ctx: BDD.Context, count: Int) -> BDD.Context
  found = outcomes(ctx).size
  BDD.assert(ctx, found == count and Conformance.names().size == count, "the suite has #{found} cases, not #{count}")
end

def expect_no_failure(ctx: BDD.Context) -> BDD.Context
  failed = outcomes(ctx).filter(->(line) { line.start_with?("failed") })
  BDD.assert(ctx, failed.empty?, "cases failed: #{failed.join("; ")}")
end

def expect_status(ctx: BDD.Context, name: String, word: String) -> BDD.Context
  want = "#{word}\t#{name}"
  BDD.assert(ctx, outcomes(ctx).include?(want), "no case #{name} #{word}; the outcomes are #{outcomes(ctx)}")
end

# Sends the calls of a script to the driver, one after the other, and stops at the first reply that is not the model's.
def agree_with_model(ctx: BDD.Context, count: Int, seed: Int) -> BDD.Context
  calls = Model.script(seed, count)
  current = ctx
  position = 0
  for call in calls
    current = ask(current, call.req)
    reply = JSON.string(BDD.get(current, REPLY).unwrap!).unwrap_or("")
    current = BDD.assert(
      current,
      reply == call.reply,
      "call #{position} of the seed #{seed}, #{JSON.encode(call.req)}: the backend says #{reply}, " +
      "the model says #{call.reply}",
    )

    position += 1
  end

  BDD.assert(current, calls.size == count + 1, "the model wrote #{calls.size} calls")
end

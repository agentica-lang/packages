## The steps of the features. Most of them drive the memory backend through `driver.agc`, which holds the backend and
## the clock (see `protocol.agc`): a step cannot keep the backend's actor between steps.

import BDD from "std/bdd"
import {Request} from "protocol"

private

REPLY_MS = 60_000
MODEL = "specs/fixtures/model.py"
MODEL_MS = 30_000
LEASE_MS = 30_000
REPLY = "reply"
HEADER = [["setting", "value"]]

# One call of the model's script: the request, and the reply that the model gave.
struct Call
  req: Request
  reply: String
end

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
    BDD.step("I ack {string}") do |ctx, args| ask(ctx, Request(op: "ack", name: args[0])) end,
    BDD.step("I retry {string} in {int} ms") do |ctx, args|
      ask(ctx, Request(op: "retry", name: args[0], number: args[1].to_i!))
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
    BDD.step("the clock moves {int} ms at a time until the fetch {string} ends") do |ctx, args|
      ask(ctx, Request(op: "wait_end", name: args[1], number: args[0].to_i!))
    end,
    BDD.step("I drain {string}") do |ctx, args| ask(ctx, Request(op: "drain", queue: args[0], kind: "ready")) end,
    BDD.step("I drain {string}, with the jobs that wait for a time") do |ctx, args|
      ask(ctx, Request(op: "drain", queue: args[0], kind: "all"))
    end,
    BDD.step("{int} consumers work off {int} jobs of one queue while producers add them") do |ctx, args|
      ask(ctx, Request(op: "stress", number: args[0].to_i!, wait: args[1].to_i!))
    end,
    BDD.step("the memory backend answers like the model on {int} random calls from seed {int}") do |ctx, args|
      agree_with_model(ctx, args[0].to_i!, args[1].to_i!)
    end,
    BDD.step("the reply is {string}") do |ctx, args| expect_reply(ctx, args[0]) end,
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

# Sends the calls of a script to the driver, one after the other, and stops at the first reply that is not the model's.
def agree_with_model(ctx: BDD.Context, count: Int, seed: Int) -> BDD.Context
  calls = model_calls(count, seed)
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

def model_calls(count: Int, seed: Int) -> List[Call]
  process = Process.spawn_captured(
    "python3",
    [MODEL, "#{seed}", "#{count}"],
    Process.Options(timeout_ms: MODEL_MS),
  ).unwrap!

  output = Process.output(process, MODEL_MS).unwrap!
  _ = Process.wait(process, MODEL_MS)
  lines = output.stdout.split("\n").select { |line| line != "" }
  lines.map { |line| JSON.decode(line, Call).unwrap! }
end

## The steps of the features. They drive the hub through `driver.agc`, which holds it with its handlers (see
## `protocol.agc`): a step cannot keep the tasks of the package running between steps.

import BDD from "std/bdd"
import {Request} from "protocol"

private

REPLY_MS = 60_000
REPLY = "reply"
STOP_MS = 5_000

def main() -> Void
  BDD.run([
    BDD.step("the hub is started") do |ctx, _args| ask(ctx, Request(op: "start")) end,
    BDD.step("I stop the hub") do |ctx, _args| ask(ctx, Request(op: "stop", number: STOP_MS)) end,
    BDD.step("I attach {string} to {string}") do |ctx, args| attach(ctx, args, "record", 0) end,
    BDD.step("I attach {string} to {string} with a queue of {int}") do |ctx, args|
      attach(ctx, args, "record", args[2].to_i!)
    end,
    BDD.step("I attach {string} to {string} and it fails") do |ctx, args| attach(ctx, args, "fail", 0) end,
    BDD.step("I attach {string} to {string} and it crashes") do |ctx, args| attach(ctx, args, "crash", 0) end,
    BDD.step("I attach {string} to {string} and it blocks, with a queue of {int}") do |ctx, args|
      attach(ctx, args, "block", args[2].to_i!)
    end,
    BDD.step("I detach {string}") do |ctx, args| ask(ctx, Request(op: "detach", id: args[0])) end,
    BDD.step("I release {string}") do |ctx, args| ask(ctx, Request(op: "release", id: args[0])) end,
    BDD.step("I emit {string}") do |ctx, args| ask(ctx, Request(op: "execute", name: args[0])) end,
    BDD.step("I emit {string} with:") do |ctx, args|
      ask(ctx, Request(op: "execute", name: args[0], table: BDD.table(ctx)))
    end,
    BDD.step("I emit {int} events {string}") do |ctx, args|
      ask(ctx, Request(op: "flood", name: args[1], number: args[0].to_i!))
    end,
    BDD.step("I flush") do |ctx, _args| ask(ctx, Request(op: "flush")) end,
    BDD.step("I ask for the handlers") do |ctx, _args| ask(ctx, Request(op: "handlers")) end,
    BDD.step("I ask whether {string} is enabled") do |ctx, args| ask(ctx, Request(op: "enabled", name: args[0])) end,
    BDD.step("I wait for the tasks of the hub to end") do |ctx, _args| ask(ctx, Request(op: "idle")) end,
    BDD.step(
      "{int} tasks attach, emit {int} events each and detach, while one handler hears everything",
    ) do |ctx, args| ask(ctx, Request(op: "stress", number: args[0].to_i!, wait: args[1].to_i!)) end,
    BDD.step("the reply is {string}") do |ctx, args| expect_reply(ctx, args[0]) end,
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

def attach(ctx: BDD.Context, args: List[String], mode: String, capacity: Int) -> BDD.Context
  ask(ctx, Request(op: "attach", id: args[0], patterns: args[1].split(","), mode: mode, number: capacity))
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

# What the reply `ok A | B` of a read holds: the items A and B.
def items(reply: String) -> List[String]
  text = reply.replace("ok ", "")
  return [] if reply == "ok" or text == ""

  text.split(" | ")
end

# Asks for what the handler recorded, as the driver wrote it, one text per event: the context holds the answer.
def read_log(ctx: BDD.Context, id: String) -> BDD.Context = ask(ctx, Request(op: "log", id: id))

def read_dropped(ctx: BDD.Context, id: String) -> BDD.Context = ask(ctx, Request(op: "dropped", id: id))

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
  asked = ask(ctx, Request(op: "warnings"))
  got = items(reply(asked)).join("\n")
  BDD.assert(asked, got == want.strip, "the Logger got:\n#{got}\nand should get:\n#{want}")
end

def expect_clean(ctx: BDD.Context, text: String) -> BDD.Context
  asked = ask(ctx, Request(op: "warnings"))
  found = items(reply(asked)).select(->(line) { line.include?(text) })
  BDD.assert(asked, found.empty?, "a warning includes #{text}: #{found}")
end

## The steps of the features. They drive `HttpClient` through `driver.agc`, which holds the client and its requests
## (see `protocol.agc`); the server is `fixtures/peer.py`, an HTTP/1.1 server of Python's standard library that says
## which TCP connection served each response (`x-connection`).

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

private

REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("the peer {string} listens") do |ctx, args| send(ctx, Request(op: "peer", name: args[0])) end,
    BDD.step("the peer {string} listens and closes idle connections after {int} ms") do |ctx, args|
      send(ctx, Request(op: "peer", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("a client of {string} with:") do |ctx, args|
      send(ctx, Request(op: "client", name: args[0], table: BDD.table(ctx)))
    end,
    BDD.step("{string} sends {string} to {string}") do |ctx, args|
      send(ctx, Request(op: "send", name: args[0], kind: args[1], text: args[2]))
    end,
    BDD.step("{string} sends {string} to {string} with the body {string}") do |ctx, args|
      send(ctx, Request(op: "send", name: args[0], kind: args[1], text: args[2], body: args[3]))
    end,
    BDD.step("{string} sends {string} to {string} with the header {string}") do |ctx, args|
      send(ctx, Request(op: "send", name: args[0], kind: args[1], text: args[2], header: args[3]))
    end,
    BDD.step("{string} starts {string} to {string}") do |ctx, args|
      send(ctx, Request(op: "start", name: args[0], kind: args[1], text: args[2]))
    end,
    BDD.step("I wait for {string}") do |ctx, args| send(ctx, Request(op: "wait", name: args[0])) end,
    BDD.step("I wait {int} ms") do |ctx, args| send(ctx, Request(op: "sleep", number: args[0].to_i!)) end,
    BDD.step("I close the client") do |ctx, _args| send(ctx, Request(op: "close")) end,
    BDD.step("{string} has the status {int}") do |ctx, args|
      send(ctx, Request(op: "expect_status", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("{string} has the body {string}") do |ctx, args|
      send(ctx, Request(op: "expect_body", name: args[0], text: args[1]))
    end,
    BDD.step("{string} has the header {string}") do |ctx, args|
      send(ctx, Request(op: "expect_header", name: args[0], text: args[1]))
    end,
    BDD.step("{string} came on connection {int}") do |ctx, args|
      send(ctx, Request(op: "expect_header", name: args[0], text: "x-connection: #{args[1]}"))
    end,
    BDD.step("{string} fails with the kind {string}") do |ctx, args|
      send(ctx, Request(op: "expect_kind", name: args[0], text: args[1]))
    end,
    BDD.step("{string} ended within {int} ms") do |ctx, args|
      send(ctx, Request(op: "expect_within", name: args[0], number: args[1].to_i!))
    end,
  ])
end

# Sends the request to the driver, started on the first one, and checks that it answers ok. The driver puts what went
# wrong in the reply, which shows as the actual line of the failed check.
def send(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end

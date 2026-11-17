## The steps of the features. They drive `HttpClient` through `driver.agc`, which holds the client, its requests and
## the peers (see `protocol.agc`). A peer is the server of `std/http` (`fixtures/server.agc`) or a raw peer that
## writes the answers of a script by hand and says which TCP connection served each one (`fixtures/raw_peer.agc`).

import BDD from "std/bdd"
import Protocol from "protocol"
import {Request} from "protocol"

private

REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("the server {string} listens") do |ctx, args|
      send(ctx, Request(op: "peer", name: args[0], kind: "server"))
    end,
    BDD.step("the raw peer {string} listens with the script:") do |ctx, args|
      send(ctx, Request(op: "peer", name: args[0], kind: "raw", text: BDD.doc_string(ctx)))
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
    BDD.step("the port {string} is closed") do |ctx, args| send(ctx, Request(op: "dead_port", name: args[0])) end,
    BDD.step("the peer {string} has read request {int}") do |ctx, args|
      send(ctx, Request(op: "read", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("the peer {string} has read only {int} requests") do |ctx, args|
      send(ctx, Request(op: "read_only", name: args[0], number: args[1].to_i!))
    end,
    BDD.step("I wait for {string}") do |ctx, args| send(ctx, Request(op: "wait", name: args[0])) end,
    BDD.step("the task of {string} is cancelled") do |ctx, args| send(ctx, Request(op: "cancel", name: args[0])) end,
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
    BDD.step("{string} ended at {string}") do |ctx, args|
      send(ctx, Request(op: "expect_url", name: args[0], text: args[1]))
    end,
    BDD.step("{string} took at least {int} ms") do |ctx, args|
      send(ctx, Request(op: "expect_after", name: args[0], number: args[1].to_i!))
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

  # The driver starts the peers with the agentica that runs the specs.
  command = ctx.scenario.settings.agentica
  with_env = ctx
  # A relative path names a file from the folder of the run, not from the driver's, so only a full path or a name
  # found in PATH goes.
  if not command.empty? and (command[0].start_with?("/") or not command[0].include?("/"))
    with_env = BDD.given_env(ctx, "HTTP_CLIENT_AGENTICA", command[0])
  end

  BDD.set(BDD.given_program(with_env, "driver.agc"), "driver", JSON.from(true))
end

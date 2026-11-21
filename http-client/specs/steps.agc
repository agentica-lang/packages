## The steps of the features. They drive `HttpClient` through `driver.agc`, which holds the client, its requests and
## the peers (see `protocol.agc`). A peer is the server of `std/http` (`fixtures/server.agc`) or a raw peer that
## writes the answers of a script by hand and says which TCP connection served each one (`fixtures/raw_peer.agc`).

import BDD from "std/bdd"
import H2Steps from "h2_steps"
import Protocol from "protocol"
import {Call, Check, Expectation, How, Reads, Request, Script, Setup} from "protocol"

private

REPLY_MS = 60_000

def main() -> Void
  BDD.run([
    BDD.step("HTTP/2 reports the limiting deadline", &H2Steps.deadlines),
    BDD.step("an unsent HTTP/2 POST reconnects and returns the early response", &H2Steps.early),
    BDD.step("HTTP/2 startup rejects invalid settings and respects an adjacent GOAWAY", &H2Steps.startup),
    BDD.step("the HTTP/2 client finds h2 on the second resolved address", &H2Steps.alternate),
    BDD.step("an HTTP/2 client reuses the socket and obeys flow control", &H2Steps.flow),
    BDD.step("the HTTP/2 client checks ALPN against a TLS peer", &H2Steps.tls),
    BDD.step("the server {string} listens") do |ctx, args| send(ctx, Request.Server(args[0])) end,
    BDD.step("the TLS server {string} listens") do |ctx, args| send(ctx, Request.TlsServer(args[0])) end,
    BDD.step("the resolver was asked {int} times") do |ctx, args| send(ctx, Request.Asked(args[0].to_i!)) end,
    BDD.step("the raw peer {string} listens with the script:") do |ctx, args|
      send(ctx, Request.Raw(Script(name: args[0], text: BDD.doc_string(ctx))))
    end,
    BDD.step("a client of {string} with:") do |ctx, args|
      send(ctx, Request.Client(Setup(name: args[0], table: BDD.table(ctx))))
    end,
    BDD.step("{string} sends {string} to {string}") do |ctx, args| send(ctx, Request.Send(call(args, How.Plain))) end,
    BDD.step("{string} sends {string} to {string} with the body {string}") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Plain).with(body: args[3])))
    end,
    BDD.step("{string} sends {string} to {string} with the header {string}") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Plain).with(header: args[3])))
    end,
    BDD.step("{string} sends {string} to {string} with the JSON {string}") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Plain).with(json: args[3])))
    end,
    BDD.step("{string} sends {string} to {string} with the param {string}") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Plain).with(param: args[3])))
    end,
    BDD.step("{string} streams {string} from {string}") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Stream)))
    end,
    BDD.step("{string} streams {string} from {string} and closes it after the first piece") do |ctx, args|
      send(ctx, Request.Send(call(args, How.StreamFirst)))
    end,
    BDD.step("{string} streams {string} from {string} and cancels it after the first piece") do |ctx, args|
      send(ctx, Request.Send(call(args, How.StreamCancelFirst)))
    end,
    BDD.step("{string} streams {string} from {string} and cancels it after reading it") do |ctx, args|
      send(ctx, Request.Send(call(args, How.StreamCancel)))
    end,
    BDD.step(
      "{string} starts a stream of {string} from {string} and cancels it after the first piece in {int} ms",
    ) do |ctx, args| send(ctx, Request.Start(call(args, How.StreamCancelFirst).with(pace_ms: args[3].to_i!))) end,
    BDD.step(
      "{string} streams {string} from {string} and releases the raw peer {string} after the first piece",
    ) do |ctx, args| send(ctx, Request.Send(call(args, How.StreamReleased).with(release: args[3]))) end,
    BDD.step("{string} reads the events of {string}") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.Events)))
    end,
    BDD.step("{string} streams {string} from {string} and reads it after {int} ms") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Stream).with(wait_ms: args[3].to_i!)))
    end,
    BDD.step("{string} streams {string} from {string} taking a piece every {int} ms") do |ctx, args|
      send(ctx, Request.Send(call(args, How.Stream).with(pace_ms: args[3].to_i!)))
    end,
    BDD.step("{string} reads the events of {string} taking one every {int} ms") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.Events).with(pace_ms: args[2].to_i!)))
    end,
    BDD.step("{string} reads the events of {string} in a task that is cancelled after {int} ms") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.EventsAbandoned).with(wait_ms: args[2].to_i!)))
    end,
    BDD.step("{string} reads the events of {string} in a task that crashes after the first") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.EventsAbandoned).with(crash: true)))
    end,
    BDD.step("{string} reads the events of {string} a second time") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.EventsTwice)))
    end,
    BDD.step("{string} closes the events of {string} after {int} ms") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.EventsClosed).with(wait_ms: args[2].to_i!)))
    end,
    BDD.step("{string} reads the events of {string} after {int} ms") do |ctx, args|
      send(ctx, Request.Send(events_call(args, How.Events).with(wait_ms: args[2].to_i!)))
    end,
    BDD.step("{string} starts {string} to {string}") do |ctx, args|
      send(ctx, Request.Start(call(args, How.Plain)))
    end,
    BDD.step("the port {string} is closed") do |ctx, args| send(ctx, Request.DeadPort(args[0])) end,
    BDD.step("the peer {string} has read request {int}") do |ctx, args|
      send(ctx, Request.Read(Reads(name: args[0], count: args[1].to_i!)))
    end,
    BDD.step("the peer {string} has read only {int} requests") do |ctx, args|
      send(ctx, Request.ReadOnly(Reads(name: args[0], count: args[1].to_i!)))
    end,
    BDD.step("I wait for {string}") do |ctx, args| send(ctx, Request.Wait(args[0])) end,
    BDD.step("the task of {string} is cancelled") do |ctx, args| send(ctx, Request.Cancel(args[0])) end,
    BDD.step("I wait {int} ms") do |ctx, args| send(ctx, Request.Sleep(args[0].to_i!)) end,
    BDD.step("I close the client") do |ctx, _args| send(ctx, Request.Close) end,
    BDD.step("{string} has the status {int}") do |ctx, args|
      send(ctx, expect(args[0], Check.Status(args[1].to_i!)))
    end,
    BDD.step("{string} has the body {string}") do |ctx, args| send(ctx, expect(args[0], Check.Body(args[1]))) end,
    BDD.step("{string} has the header {string}") do |ctx, args| send(ctx, expect(args[0], Check.Header(args[1]))) end,
    BDD.step("{string} came on connection {int}") do |ctx, args|
      send(ctx, expect(args[0], Check.Header("x-connection: #{args[1]}")))
    end,
    BDD.step("{string} fails with the kind {string}") do |ctx, args|
      send(ctx, expect(args[0], Check.Kind(args[1])))
    end,
    BDD.step("{string} ended at {string}") do |ctx, args| send(ctx, expect(args[0], Check.Url(args[1]))) end,
    BDD.step("{string} has a body of {int} bytes") do |ctx, args|
      send(ctx, expect(args[0], Check.Size(args[1].to_i!)))
    end,
    BDD.step("{string} decodes to the person {string}") do |ctx, args|
      send(ctx, expect(args[0], Check.Decoded(args[1])))
    end,
    BDD.step("{string} does not decode") do |ctx, args|
      send(ctx, expect(args[0], Check.Decoded("http_client.decode")))
    end,
    BDD.step("{string} took at least {int} ms") do |ctx, args|
      send(ctx, expect(args[0], Check.After(args[1].to_i!)))
    end,
    BDD.step("{string} ended within {int} ms") do |ctx, args|
      send(ctx, expect(args[0], Check.Within(args[1].to_i!)))
    end,
  ])
end

# A request of the client: the name, the method and the URL of the step.
def call(args: List[String], how: How) -> Call = Call(name: args[0], method: args[1], url: args[2], how: how)

# The events of a URL are read with a `GET`: the name and the URL of the step.
def events_call(args: List[String], how: How) -> Call = Call(name: args[0], url: args[1], how: how)

def expect(name: String, check: Check) -> Request = Request.Expect(Expectation(name: name, check: check))

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

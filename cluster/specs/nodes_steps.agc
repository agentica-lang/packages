## The steps of nodes.feature. They send requests (`nodes_protocol.agc`) to `driver.agc`, which holds the nodes of the
## scenario, and check that it answers `ok`; what went wrong is the reply, which shows as the actual line of the check.

import BDD from "std/bdd"
import Protocol from "nodes_protocol"
import {Connect, Peers, Refusals, Request, Spec, Stranger, Visit} from "nodes_protocol"

def steps() -> List[BDD.Step]
  [
    BDD.step("the node {string} starts with the cookie {string}", &starts),
    BDD.step("the node {string} starts with the cookie {string} and dials {string}", &starts_dialing),
    BDD.step("the node {string} starts with the cookie {string} and dials {string} by its name", &starts_naming),
    BDD.step("the node {string} starts with the cookie {string} and a deadline of {int} ms", &starts_with_deadline),
    BDD.step(
      "starting the node {string} on the host {string} with the cookie {string} fails with {string}",
      &fails_host,
    ),
    BDD.step("starting the node {string} with the peer {string} fails with {string}", &fails_peer),
    BDD.step("starting the node {string} with the cookie {string} fails with {string}", &fails_cookie),
    BDD.step("{string} connects to the node {string}", &connects),
    BDD.step("{string} connects to the node {string} and it fails with {string}", &connect_fails),
    BDD.step(
      "{string} connects to the node {string} expecting the name {string} and it fails with {string}",
      &name_fails,
    ),
    BDD.step("{string} connects to the address {string} and it fails with {string}", &address_fails),
    BDD.step("{string} and {string} connect to each other at the same moment", &connect_both),
    BDD.step("{string} has the peers {string} within {int} ms", &has_peers),
    BDD.step("{string} still has the peers {string} {int} ms later", &still_has_peers),
    BDD.step("{string} has refused {int} handshakes", &refused),
    BDD.step("the node {string} stops", &stops),
    BDD.step("a stranger writes {string} to {string} and is disconnected within {int} ms", &stranger_text),
    BDD.step(
      "a stranger sends {string} a frame of {int} bytes before the handshake and is disconnected",
      &stranger_big,
    ),
    BDD.step("a stranger sends {string} a ping before the handshake and is disconnected", &stranger_ping),
    BDD.step(
      "a stranger answers {string} with a proof that it made up and is disconnected, with nothing said",
      &stranger_wrong,
    ),
    BDD.step("a stranger says nothing to {string} and is disconnected within {int} ms", &stranger_silent),
  ]
end

private

REPLY_MS = 60_000
COOKIE = "a-cookie-of-more-than-16-bytes"
CLOSE_MS = 3000

def list_of(text: String) -> List[String]
  return [] if text.strip.empty?

  text.split(",").map { |part| part.strip }
end

def send(ctx: BDD.Context, request: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(request))
  BDD.then_line(asked, Protocol.OK, REPLY_MS)
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end

def starts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1])))
end

def starts_dialing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], dials: list_of(args[2]))))
end

def starts_naming(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], dials: list_of(args[2]), named: true)))
end

def starts_with_deadline(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], connect_ms: args[2].to_i!)))
end

def fails_host(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.StartFails(Spec(name: args[0], host: args[1], cookie: args[2]), args[3]))
end

def fails_peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: COOKIE, addresses: [args[1]])
  send(ctx, Request.StartFails(spec, args[2]))
end

def fails_cookie(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.StartFails(Spec(name: args[0], cookie: args[1]), args[2]))
end

def connects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Connect(Connect(from: args[0], to: args[1])))
end

def connect_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Connect(Connect(from: args[0], to: args[1], kind: args[2])))
end

def name_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Connect(Connect(from: args[0], to: args[1], as_name: args[2], kind: args[3])))
end

def address_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Connect(Connect(from: args[0], to: args[0], address: args[1], kind: args[2])))
end

def connect_both(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.ConnectBoth(args[0], args[1]))
end

def has_peers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Peers(Peers(node: args[0], names: list_of(args[1]), within_ms: args[2].to_i!)))
end

def still_has_peers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Peers(Peers(node: args[0], names: list_of(args[1]), within_ms: 1, hold_ms: args[2].to_i!)))
end

def refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Refusals(Refusals(node: args[0], count: args[1].to_i!, within_ms: CLOSE_MS)))
end

def stops(ctx: BDD.Context, args: List[String]) -> BDD.Context = send(ctx, Request.Stop(args[0]))

def stranger_text(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = args[0].replace("\\r", "\r").replace("\\n", "\n")
  send(ctx, Request.Visit(Visit(node: args[1], stranger: Stranger.Text(text), within_ms: args[2].to_i!)))
end

def stranger_big(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Visit(Visit(node: args[0], stranger: Stranger.Big(args[1].to_i!), within_ms: CLOSE_MS)))
end

def stranger_ping(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Visit(Visit(node: args[0], stranger: Stranger.Ping, within_ms: CLOSE_MS)))
end

def stranger_silent(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Visit(Visit(node: args[0], stranger: Stranger.Silence, within_ms: args[1].to_i!)))
end

def stranger_wrong(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Visit(Visit(node: args[0], stranger: Stranger.WrongProof, within_ms: CLOSE_MS)))
end

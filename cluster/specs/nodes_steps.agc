## The steps of nodes.feature. They send requests (`nodes_protocol.agc`) to `driver.agc`, which holds the nodes of the
## scenario, and check that it answers `ok`; what went wrong is the reply, which shows as the actual line of the check.

import BDD from "std/bdd"
import Protocol from "nodes_protocol"
import {
  Connect, Drops, Flood, HoleVisit, Mailbox, Payload, Peers, Post, Received, Refusals, Request, Spec,
} from "nodes_protocol"
import {Expected, Joining, Stranger, Visit} from "nodes_protocol"

def steps() -> List[BDD.Step]
  [
    BDD.step("the node {string} starts with the cookie {string}", &starts),
    BDD.step("the node {string} starts with the cookie {string} and dials {string}", &starts_dialing),
    BDD.step("the node {string} starts with the cookie {string} and dials {string} by its name", &starts_naming),
    BDD.step("the node {string} starts with the cookie {string} and a deadline of {int} ms", &starts_with_deadline),
    BDD.step("the node {string} starts with the cookie {string} and at most {int} handshakes at once", &starts_capped),
    BDD.step("a hole {string} accepts connections and never answers", &hole),
    BDD.step("{string} connects to the hole {string} and it fails with {string} within {int} ms", &connect_hole),
    BDD.step("{string} starts connecting to the hole {string}", &connect_later),
    BDD.step("{string} connects to the node {string} twice at the same moment", &connect_twice),
    BDD.step("the node {string} stops within {int} ms", &stops_within),
    BDD.step("{int} strangers connect to {string} and say nothing, and {int} of them are closed at once", &flood),
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
    BDD.step("{string} has the mailbox {string}", &registers),
    BDD.step("{string} joins the group {string} with the mailbox {string}", &joins),
    BDD.step("{string} joins the group {string} with the mailbox {string} and it fails with {string}", &join_fails),
    BDD.step("{string} leaves the group {string} with the mailbox {string}", &leaves),
    BDD.step("the members of the group {string} on {string} are {string} within {int} ms", &has_members),
    BDD.step("{string} has the mailbox {string} again", &registers),
    BDD.step("the node {string} starts with the cookie {string} and a heartbeat of {int} ms", &starts_beating),
    BDD.step(
      "the node {string} starts with the cookie {string}, dials {string} and retries every {int} ms",
      &starts_retrying,
    ),
    BDD.step("the node {string} starts again on the port of its first run with the cookie {string}", &starts_again),
    BDD.step(
      "the node {string} starts with the cookie {string} and finds nodes at {string}, port of {string}, each {int} ms",
      &starts_discovering,
    ),
    BDD.step(
      "the node {string} starts with the cookie {string} and finds the name {string} on a trusted network, each {int} ms",
      &starts_discovering_a_name,
    ),
    BDD.step("starting the node {string} that finds the nodes at {string} fails with {string}", &fails_discover),
    BDD.step(
      "the node {string} starts again on the port of its first run with the cookie {string} and dials {string}",
      &starts_again_dialing,
    ),
    BDD.step(
      "the node {string} starts with the cookie {string}, dials {string} and retries every {int} ms, at most {int} ms",
      &starts_retrying_bounded,
    ),
    BDD.step("starting the node {string} with a heartbeat of {int} ms fails with {string}", &fails_heartbeat),
    BDD.step("starting the node {string} that retries every {int} ms fails with {string}", &fails_retry),
    BDD.step("{string} watches the peers coming and going", &watches),
    BDD.step("the events of {string} within {int} ms:", &has_events),
    BDD.step("the last event of {string} is {string} within {int} ms", &has_last_event),
    BDD.step("{string} has the mailbox {string} with room for {int} messages and nobody reads it", &registers_unread),
    BDD.step("the replaced mailbox {string} of {string} has received nothing", &replaced_is_empty),
    BDD.step(
      "{string} sends {string} the job {int} named {string} in {string} with {int} ms and it fails with {string}",
      &send_fails_in_time,
    ),
    BDD.step("starting the node {string} with a frame limit of {int} bytes fails with {string}", &fails_frame_limit),
    BDD.step("{string} cannot have the mailbox {string} and it fails with {string}", &register_fails),
    BDD.step("{string} sends {string} the job {int} named {string} in the mailbox {string}", &sends_job),
    BDD.step("{string} sends {string} {int} jobs in the mailbox {string}", &sends_jobs),
    BDD.step("{string} sends {string} the bytes {string} in the mailbox {string}", &sends_garbage),
    BDD.step("{string} sends {string} a message of another type in the mailbox {string}", &sends_other),
    BDD.step(
      "{string} sends {string} a message of {int} bytes in the mailbox {string} and it fails with {string}",
      &sends_big,
    ),
    BDD.step(
      "{string} sends {string} the job {int} named {string} in the mailbox {string} and it fails with {string}",
      &send_fails,
    ),
    BDD.step("the mailbox {string} of {string} has received within {int} ms:", &has_received),
    BDD.step(
      "the mailbox {string} of {string} has received {int} jobs in order within {int} ms",
      &has_received_in_order,
    ),
    BDD.step("{string} has dropped {int} messages within {int} ms", &has_dropped),
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

def starts_capped(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], max_pending: args[2].to_i!)))
end

def hole(ctx: BDD.Context, args: List[String]) -> BDD.Context = send(ctx, Request.Hole(args[0]))

def connect_hole(ctx: BDD.Context, args: List[String]) -> BDD.Context
  visit = HoleVisit(from: args[0], hole: args[1], kind: args[2], within_ms: args[3].to_i!)
  send(ctx, Request.ConnectHole(visit))
end

def connect_later(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.ConnectLater(HoleVisit(from: args[0], hole: args[1])))
end

def connect_twice(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.ConnectTwice(args[0], args[1]))
end

def stops_within(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.StopWithin(args[0], args[1].to_i!))
end

def flood(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Flood(Flood(node: args[1], count: args[0].to_i!, closed: args[2].to_i!)))
end

def joins(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Join(Joining(node: args[0], group: args[1], mailbox: args[2])))
end

def join_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.JoinFails(Joining(node: args[0], group: args[1], mailbox: args[2]), args[3]))
end

def leaves(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Leave(Joining(node: args[0], group: args[1], mailbox: args[2])))
end

def has_members(ctx: BDD.Context, args: List[String]) -> BDD.Context
  expected = Expected(node: args[1], group: args[0], members: list_of(args[2]), within_ms: args[3].to_i!)
  send(ctx, Request.Members(expected))
end

def registers(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Register(Mailbox(node: args[0], name: args[1])))
end

def register_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.RegisterFails(Mailbox(node: args[0], name: args[1]), args[2]))
end

def post(ctx: BDD.Context, from: String, to: String, mailbox: String, payload: Payload) -> BDD.Context
  send(ctx, Request.Post(Post(from: from, to: to, mailbox: mailbox, payload: payload)))
end

def sends_job(ctx: BDD.Context, args: List[String]) -> BDD.Context
  post(ctx, args[0], args[1], args[4], Payload.Job(args[2].to_i!, args[3]))
end

def sends_jobs(ctx: BDD.Context, args: List[String]) -> BDD.Context
  post(ctx, args[0], args[1], args[3], Payload.Jobs(args[2].to_i!))
end

def sends_garbage(ctx: BDD.Context, args: List[String]) -> BDD.Context
  post(ctx, args[0], args[1], args[3], Payload.Garbage(args[2]))
end

def sends_other(ctx: BDD.Context, args: List[String]) -> BDD.Context
  post(ctx, args[0], args[1], args[2], Payload.Other)
end

def sends_big(ctx: BDD.Context, args: List[String]) -> BDD.Context
  request = Post(from: args[0], to: args[1], mailbox: args[3], payload: Payload.Big(args[2].to_i!), kind: args[4])
  send(ctx, Request.Post(request))
end

def send_fails(ctx: BDD.Context, args: List[String]) -> BDD.Context
  payload = Payload.Job(args[2].to_i!, args[3])
  send(ctx, Request.Post(Post(from: args[0], to: args[1], mailbox: args[4], payload: payload, kind: args[5])))
end

def has_received(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = BDD.table(ctx).map { |row| row[0] }
  send(ctx, Request.Received(Received(node: args[1], mailbox: args[0], lines: lines, within_ms: args[2].to_i!)))
end

def has_received_in_order(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.InOrder(args[1], args[0], args[2].to_i!, args[3].to_i!))
end

def has_dropped(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Drops(Drops(node: args[0], count: args[1].to_i!, within_ms: args[2].to_i!)))
end

def registers_unread(ctx: BDD.Context, args: List[String]) -> BDD.Context
  mailbox = Mailbox(node: args[0], name: args[1], capacity: args[2].to_i!, reading: false)
  send(ctx, Request.Register(mailbox))
end

def replaced_is_empty(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.ReplacedEmpty(args[1], args[0]))
end

def send_fails_in_time(ctx: BDD.Context, args: List[String]) -> BDD.Context
  payload = Payload.Job(args[2].to_i!, args[3])
  request = Post(
    from: args[0],
    to: args[1],
    mailbox: args[4],
    payload: payload,
    kind: args[6],
    timeout_ms: args[5].to_i!,
  )

  send(ctx, Request.Post(request))
end

def fails_frame_limit(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: "the-cookie-of-the-cluster", max_frame_bytes: args[1].to_i!)
  send(ctx, Request.StartFails(spec, args[2]))
end

def starts_beating(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], heartbeat_ms: args[2].to_i!)))
end

def fails_heartbeat(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: "the-cookie-of-the-cluster", heartbeat_ms: args[1].to_i!)
  send(ctx, Request.StartFails(spec, args[2]))
end

def watches(ctx: BDD.Context, args: List[String]) -> BDD.Context = send(ctx, Request.Watch(args[0]))

def has_events(ctx: BDD.Context, args: List[String]) -> BDD.Context
  lines = BDD.table(ctx).map { |row| row[0] }
  send(ctx, Request.Received(Received(node: args[0], mailbox: "events", lines: lines, within_ms: args[1].to_i!)))
end

def has_last_event(ctx: BDD.Context, args: List[String]) -> BDD.Context
  received = Received(node: args[0], mailbox: "events", lines: [args[1]], within_ms: args[2].to_i!, last_only: true)
  send(ctx, Request.Received(received))
end

def starts_retrying(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: args[1], dials: list_of(args[2]), reconnect_ms: args[3].to_i!)
  send(ctx, Request.Start(spec))
end

def starts_again(ctx: BDD.Context, args: List[String]) -> BDD.Context
  send(ctx, Request.Start(Spec(name: args[0], cookie: args[1], again: true)))
end

def fails_retry(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: "the-cookie-of-the-cluster", reconnect_ms: args[1].to_i!)
  send(ctx, Request.StartFails(spec, args[2]))
end

def starts_again_dialing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: args[1], again: true, dials: list_of(args[2]))
  send(ctx, Request.Start(spec))
end

def starts_retrying_bounded(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(
    name: args[0],
    cookie: args[1],
    dials: list_of(args[2]),
    reconnect_ms: args[3].to_i!,
    reconnect_max_ms: args[4].to_i!,
  )

  send(ctx, Request.Start(spec))
end

def starts_discovering(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: args[1], discover: args[2], discover_port_of: args[3], discover_ms: args[4].to_i!)
  send(ctx, Request.Start(spec))
end

def starts_discovering_a_name(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: args[1], discover: args[2], discover_ms: args[3].to_i!, insecure: true)
  send(ctx, Request.Start(spec))
end

def fails_discover(ctx: BDD.Context, args: List[String]) -> BDD.Context
  spec = Spec(name: args[0], cookie: "the-cookie-of-the-cluster", discover: args[1])
  send(ctx, Request.StartFails(spec, args[2]))
end

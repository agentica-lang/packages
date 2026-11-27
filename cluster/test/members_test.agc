import Actor from "std/actor"
import Members from "../src/members"
import Types from "../src/types"

private

SETTLE_MS = 100

# A node, and a listener that accepts and never answers, so that a dial of it waits. The node is called zeta, so that a
# link dialed by beta replaces one that zeta dialed.
struct Fixture
  actor: Actor.Ref[Types.State, Types.Msg]
  listener: TCP.Listener
  address: String
  port: Int
end

def fixture() -> Fixture
  options = Types.Options(name: "zeta", cookie: "the-cookie-of-the-cluster", connect_ms: 5000)
  pending: ATS[String, Int] = ATS.new()
  actor = Actor.start(Members.behaviour(options, pending))
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  Fixture(actor: actor, listener: listener, address: "127.0.0.1:#{port}", port: port)
end

# Stopping the node cancels its links and its dials, so no task outlives the test.
def finish(fix: Fixture) -> Result[Void]
  TCP.close_listener(fix.listener)
  stopped = Actor.stop(fix.actor, 2000)
  # A cancelled task ends on its next turn.
  Task.sleep(SETTLE_MS)
  stopped
end

def idle(back: Channel[TaskRef]) -> Void
  _ = back.send(Task.current(), 1000)
  Task.sleep(60_000)
end

def peer(fix: Fixture, name: String, dialer: String, endpoint: String) -> Result[Types.Peer]
  back: Channel[TaskRef] = Channel.new(1)
  _ = Task.spawn(&idle, back)
  socket = try TCP.connect("127.0.0.1", fix.port, 1000)
  ok(Types.Peer(name: name, dialer: dialer, endpoint: endpoint, link: try back.recv(1000), socket: socket))
end

def dial(fix: Fixture, node: String) -> Channel[Result[String]]
  reply: Channel[Result[String]] = Channel.new(1)
  endpoint = Types.Endpoint(host: "127.0.0.1", port: fix.port, node: node)
  _ = Actor.cast(fix.actor.address, Types.Msg.Dial(endpoint, reply))
  reply
end

def link(fix: Fixture, name: String, dialer: String, endpoint: String) -> Result[Bool]
  linked = try peer(fix, name, dialer, endpoint)
  Actor.call(fix.actor.address, 1000, ->(reply) { Types.Msg.Linked(linked, reply) })
end

# Two links to one peer: one dialed by the smaller name and one by the larger. Each node sees them in some order, and
# the first one stays unless the second replaces it.
def kept(first: String, second: String) -> String
  return second if Members.replaces?(second, first)

  first
end

def test_both_nodes_keep_the_link_that_the_smaller_name_dialed_whatever_the_order() -> Result[Void]
  try Test.eq(kept("alpha", "beta"), "alpha")
  Test.eq(kept("beta", "alpha"), "alpha")
end

def test_the_four_combinations_of_dialers() -> Result[Void]
  try Test.eq(Members.replaces?("alpha", "alpha"), false)
  try Test.eq(Members.replaces?("alpha", "beta"), true)
  try Test.eq(Members.replaces?("beta", "alpha"), false)
  Test.eq(Members.replaces?("beta", "beta"), false)
end

def test_a_link_that_replaces_the_dialed_one_still_answers_the_callers() -> Result[Void]
  fix = fixture()
  waiting = dial(fix, "")
  try Test.eq(try link(fix, "beta", "zeta", fix.address), true)
  try Test.eq(try link(fix, "beta", "beta", ""), true)
  try Test.eq(try waiting.recv(1000), ok("beta"))
  # The address is not being dialed any more: a new connect is answered by the link that stayed.
  try Test.eq(try dial(fix, "beta").recv(500), ok("beta"))
  finish(fix)
end

def test_a_peer_that_dialed_us_gets_no_second_socket() -> Result[Void]
  fix = fixture()
  try Test.eq(try link(fix, "beta", "beta", ""), true)
  try Test.eq(try dial(fix, "beta").recv(500), ok("beta"))
  finish(fix)
end

def test_each_caller_gets_the_answer_for_the_name_that_it_gave() -> Result[Void]
  fix = fixture()
  right = dial(fix, "beta")
  wrong = dial(fix, "gamma")
  try Test.eq(try link(fix, "beta", "zeta", fix.address), true)
  try Test.eq(try right.recv(1000), ok("beta"))
  try Test.eq(kind_of(try wrong.recv(1000)), Types.REFUSED)
  finish(fix)
end

def test_stopping_the_node_answers_the_callers_that_wait() -> Result[Void]
  fix = fixture()
  waiting = dial(fix, "")
  try finish(fix)
  Test.eq(kind_of(try waiting.recv(1000)), Types.CLOSED)
end

def kind_of(result: Result[String]) -> String
  case result
    ok(_) -> ""
    error(e) -> e.kind
  end
end

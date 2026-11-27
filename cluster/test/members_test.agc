import Actor from "std/actor"
import Cluster from "../cluster"
import Members from "../src/members"
import Types from "../src/types"

private

WAIT_MS = 1000
RETRY_MS = 100
POLL_MS = 10

# A node, and a listener that accepts and never answers, so that a dial of it waits. The node is called zeta, so that a
# link dialed by beta replaces one that zeta dialed.
struct Fixture
  actor: Actor.Ref[Types.State, Types.Msg]
  listener: TCP.Listener
  address: String
  port: Int
end

# A link of a peer: a task that owns a connection and sleeps until the node cancels it.
struct Link
  name: String
  dialer: String
  endpoint: String
  port: Int
  back: Channel[Types.Peer]
end

def fixture(retry_ms: Int = 500, retry_max_ms: Int = 30_000) -> Fixture
  options = Types.Options(
    name: "zeta",
    cookie: "the-cookie-of-the-cluster",
    connect_ms: 5000,
    reconnect_ms: retry_ms,
    reconnect_max_ms: retry_max_ms,
  )

  counts: ATS[String, Int] = ATS.new()
  actor = Actor.start(Members.behaviour(options, counts))
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  port = TCP.local_port(listener)
  Fixture(actor: actor, listener: listener, address: "127.0.0.1:#{port}", port: port)
end

# Stopping the node waits for its links and its dials to end, so no task outlives the test.
def finish(fix: Fixture) -> Result[Void]
  TCP.close_listener(fix.listener)
  stopped = Actor.stop(fix.actor, 2000)
  wait_for_tasks()
  stopped
end

# The links and dials that the node replaced were cancelled before the stop: they end on their next turn.
def wait_for_tasks() -> Void
  deadline = Time.monotonic_ms() + WAIT_MS
  while Task.pending_count() > 0 and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end
end

def idle(link: Link) -> Void
  socket = TCP.connect("127.0.0.1", link.port, 1000).unwrap!
  peer = Types.Peer(
    name: link.name,
    dialer: link.dialer,
    endpoint: link.endpoint,
    link: Task.current(),
    socket: socket,
  )

  _ = link.back.send(peer, 1000)
  Task.sleep(60_000)
end

def peer(fix: Fixture, name: String, dialer: String, endpoint: String) -> Result[Types.Peer]
  back: Channel[Types.Peer] = Channel.new(1)
  _ = Task.spawn(&idle, Link(name: name, dialer: dialer, endpoint: endpoint, port: fix.port, back: back))
  back.recv(1000)
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

def test_stopping_the_node_ends_its_links() -> Result[Void]
  fix = fixture()
  linked = try peer(fix, "beta", "beta", "")
  try Test.eq(try Actor.call(fix.actor.address, 1000, ->(reply) { Types.Msg.Linked(linked, reply) }), true)
  gone: Channel[Int] = Channel.new(1)
  Task.monitor(linked.link, gone, ->(down) { down.task_id })
  try Actor.stop(fix.actor, 2000)
  try Test.eq(try gone.recv(WAIT_MS), linked.link.id)
  finish(fix)
end

# A listener that takes a connection and drops it, so that every dial fails in the handshake and the node tries again.
def attempts(fix: Fixture, wanted: Int) -> List[Int]
  times: List[Int] = []
  while times.size < wanted
    case TCP.accept(fix.listener, 3000)
      ok(socket) ->
        times = times.push(Time.monotonic_ms())
        TCP.close(socket)

      error(_) -> return times
    end
  end

  times
end

def test_a_peer_of_the_list_is_dialed_again_with_a_wait_that_doubles_up_to_the_bound() -> Result[Void]
  fix = fixture(RETRY_MS, 4 * RETRY_MS)
  _ = Actor.cast(fix.actor.address, Types.Msg.Keep([Types.Endpoint(host: "127.0.0.1", port: fix.port)]))
  times = attempts(fix, 6)
  try Test.eq(times.size, 6)
  gaps = (1..5).map { |i| times[i] - times[i - 1] }
  # The waits are 100, 200, 400, 400, 400 ms, and up to a fifth more: never less, and not far over.
  try Test.assert(
    gaps[0] >= RETRY_MS and gaps[1] >= 2 * RETRY_MS and gaps[2] >= 4 * RETRY_MS,
    "the waits were #{gaps}",
  )

  try Test.assert(gaps[3] >= 4 * RETRY_MS and gaps[4] >= 4 * RETRY_MS, "the waits were #{gaps}")
  try Test.assert(gaps[3] < 6 * RETRY_MS and gaps[4] < 6 * RETRY_MS, "the wait went over the bound: #{gaps}")
  finish(fix)
end

def found(fix: Fixture, host: String = "127.0.0.1") -> Result[Void]
  Actor.cast(fix.actor.address, Types.Msg.Found(Types.Endpoint(host: host, port: fix.port)))
end

def accepted(listener: TCP.Listener, wait_ms: Int) -> List[TCP.Socket]
  case TCP.accept(listener, wait_ms)
    ok(socket) -> [socket] + accepted(listener, wait_ms)
    error(_) -> []
  end
end

def connections(listener: TCP.Listener, wait_ms: Int) -> Int
  sockets = accepted(listener, wait_ms)
  for socket in sockets
    TCP.close(socket)
  end

  sockets.size
end

# The dials of the test are held open, so that their failure does not come before the answers that the test makes up.
def test_an_address_that_the_name_gave_is_not_dialed_again_once_its_peer_is_linked() -> Result[Void]
  fix = fixture()
  address = "127.0.0.1:#{fix.port}"
  try found(fix)
  held = accepted(fix.listener, 500)
  try Test.eq(held.size, 1)
  # The peer came in on a link of its own, and the dial of the address answered with its name.
  try Test.eq(try link(fix, "beta", "beta", ""), true)
  try Actor.cast(fix.actor.address, Types.Msg.Dialed(address, ok("beta")))
  # The link of this test opened a connection of its own.
  try Test.eq(connections(fix.listener, 300), 1)
  try found(fix)
  try Test.eq(connections(fix.listener, 500), 0)
  for socket in held
    TCP.close(socket)
  end

  finish(fix)
end

def test_a_dial_that_fails_makes_the_node_forget_the_address() -> Result[Void]
  fix = fixture()
  address = "127.0.0.1:#{fix.port}"
  try found(fix)
  try Test.eq(connections(fix.listener, 500), 1)
  try Actor.cast(
    fix.actor.address,
    Types.Msg.Dialed(address, error("cluster: no node answers", kind: Types.UNREACHABLE)),
  )

  # A name that comes late is not kept for an address that nothing asks for.
  try Actor.cast(fix.actor.address, Types.Msg.Dialed(address, ok("beta")))
  try Test.eq(try link(fix, "beta", "beta", ""), true)
  try Test.eq(connections(fix.listener, 300), 1)
  try found(fix)
  try Test.eq(connections(fix.listener, 500), 1)
  finish(fix)
end

def refused_at_least(fix: Fixture, count: Int) -> Bool
  deadline = Time.monotonic_ms() + WAIT_MS
  while Time.monotonic_ms() < deadline
    refused: Result[Int] = Actor.call(fix.actor.address, WAIT_MS, ->(reply) { Types.Msg.Refusals(reply) })
    return true if refused.unwrap_or(0) >= count

    Task.sleep(POLL_MS)
  end

  false
end

def test_an_address_of_the_list_that_the_name_gives_is_dialed_with_the_name_of_the_list() -> Result[Void]
  fix = fixture(60_000, 60_000)
  alpha = try Cluster.start(Cluster.Options(name: "alpha", cookie: "the-cookie-of-the-cluster"))
  port = Cluster.port(alpha)
  listed = Types.Endpoint(host: "127.0.0.1", port: port, node: "gamma")
  try Actor.cast(fix.actor.address, Types.Msg.Keep([listed]))
  try Test.assert(refused_at_least(fix, 1), "the dial of the list was not refused")
  try Actor.cast(fix.actor.address, Types.Msg.Found(Types.Endpoint(host: "127.0.0.1", port: port)))
  try Test.assert(refused_at_least(fix, 2), "the dial of the found address was not refused")
  try Test.eq(Cluster.nodes(alpha), [])
  try Cluster.stop(alpha, 1000)
  finish(fix)
end

def test_an_ipv6_address_is_dialed() -> Result[Void]
  fix = fixture()
  six = try TCP.listen("::1", 0)
  try Actor.cast(fix.actor.address, Types.Msg.Found(Types.Endpoint(host: "::1", port: TCP.local_port(six))))

  try Test.eq(connections(six, 1000), 1)
  TCP.close_listener(six)
  finish(fix)
end

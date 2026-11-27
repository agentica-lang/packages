import Cluster from "../cluster"
import Handshake from "../src/handshake"
import Types from "../src/types"
import Wire from "../src/wire"

private

COOKIE = "the-cookie-of-the-cluster"
HEARTBEAT_MS = 100
READ_MS = 2000
POLL_MS = 10
BLOCK_MS = 15_000

# A peer that writes a pong every 50 ms and never reads: it is alive, but it takes nothing in.
struct Chatter
  socket: TCP.Socket
end

# Sends big frames to the peer until one fails.
struct Flood
  node: Cluster.Node
  body: Bytes
end

# The tasks of a link that was cancelled end on their next turn.
def stopped(alpha: Cluster.Node) -> Result[Void]
  try Cluster.stop(alpha, 1000)
  deadline = Time.monotonic_ms() + READ_MS
  while Task.pending_count() > 0 and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  ok()
end

def node() -> Cluster.Node
  Cluster.start(Cluster.Options(name: "alpha", cookie: COOKIE, heartbeat_ms: HEARTBEAT_MS)).unwrap!
end

def watching(alpha: Cluster.Node) -> Channel[Cluster.Event]
  events: Channel[Cluster.Event] = Channel.new(16)
  Cluster.watch(alpha, events.address, ->(event) { event }).unwrap!
  events
end

def read_exact(socket: TCP.Socket, count: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    got = try TCP.recv_bytes(socket, count - have, READ_MS)
    parts = parts.push(got)
    have += got.size
  end

  ok(Bytes.concat(parts))
end

def read_frame(socket: TCP.Socket) -> Result[Types.Message]
  header = try read_exact(socket, 4)
  length = try Wire.frame_length(header, Types.MAX_FRAME_BYTES)
  Wire.decode(try read_exact(socket, length))
end

# A peer written by hand: it shakes hands as the client and then does what the test says, with no heartbeat of its own.
def raw_peer(port: Int) -> Result[TCP.Socket]
  socket = try TCP.connect("127.0.0.1", port, READ_MS)
  nonce = Handshake.fresh_nonce()
  hello = try Wire.encode(Types.Message.Hello("raw", nonce))
  try TCP.send_bytes(socket, Wire.preamble() + hello, READ_MS)
  try Wire.check_preamble(try read_exact(socket, 6))
  case try read_frame(socket)
    Types.Message.Challenge(server, server_nonce, server_proof) ->
      session = try Handshake.session("raw", server, nonce, server_nonce)
      proof = try Handshake.answer(COOKIE.bytes, session, server_proof)
      try TCP.send_bytes(socket, try Wire.encode(proof), READ_MS)
      _ = try read_frame(socket)
      ok(socket)

    _ -> error("the node did not challenge")
  end
end

def next_event(events: Channel[Cluster.Event], wait_ms: Int = READ_MS) -> String
  case events.recv(wait_ms)
    ok(Cluster.Event.NodeUp(name)) -> "up #{name}"
    ok(Cluster.Event.NodeDown(name)) -> "down #{name}"
    ok(Cluster.Event.NodeLeft(name)) -> "left #{name}"
    error(_) -> "none"
  end
end

# What a test did, and then the node stopped whatever happened: a failed check must not leave the node running.
def finished(alpha: Cluster.Node, outcome: Result[Void]) -> Result[Void]
  _ = stopped(alpha)
  outcome
end

def big_body() -> Bytes
  chunk = Bytes.from_list((1..1000).map { |_| 7 }).unwrap!
  Bytes.concat((1..900).map { |_| chunk })
end

def chatter(args: Chatter) -> Void
  pong = Wire.encode(Types.Message.Pong).unwrap!
  while TCP.send_bytes(args.socket, pong, READ_MS).ok?
    Task.sleep(50)
  end
end

def flood(args: Flood) -> Void
  while Cluster.send(args.node, "raw", "jobs", args.body, 30_000).ok?
    Task.sleep(1)
  end
end

def quiet_link_gets_a_ping(alpha: Cluster.Node) -> Result[Void]
  peer = try raw_peer(Cluster.port(alpha))
  frame = try read_frame(peer)
  TCP.close(peer)
  Test.eq(frame, Types.Message.Ping)
end

def silent_peer_is_down(alpha: Cluster.Node) -> Result[Void]
  events = watching(alpha)
  peer = try raw_peer(Cluster.port(alpha))
  try Test.eq(next_event(events), "up raw")
  started = Time.monotonic_ms()
  try Test.eq(next_event(events), "down raw")
  waited = Time.monotonic_ms() - started
  TCP.close(peer)
  try Test.assert(waited >= 2 * HEARTBEAT_MS, "it was told as down after #{waited} ms, before 2 heartbeats")
  Test.assert(waited <= 20 * HEARTBEAT_MS, "it was told as down after #{waited} ms, long after 3 heartbeats")
end

def peer_that_answers_stays_up(alpha: Cluster.Node) -> Result[Void]
  events = watching(alpha)
  peer = try raw_peer(Cluster.port(alpha))
  try Test.eq(next_event(events), "up raw")
  pong = try Wire.encode(Types.Message.Pong)
  deadline = Time.monotonic_ms() + 6 * HEARTBEAT_MS
  while Time.monotonic_ms() < deadline
    case try read_frame(peer)
      Types.Message.Ping -> try TCP.send_bytes(peer, pong, READ_MS)
      _ -> nil
    end
  end

  try Test.eq(Cluster.nodes(alpha), ["raw"])
  TCP.close(peer)
  Test.eq(next_event(events), "down raw")
end

# The peer is alive (its pongs arrive) but reads nothing, so a big send blocks on a full socket and the pings cannot be
# written: the link must end by the watcher, not wait for the send, which has 30 seconds.
def peer_that_reads_nothing_is_down(alpha: Cluster.Node) -> Result[Void]
  events = watching(alpha)
  peer = try raw_peer(Cluster.port(alpha))
  try Test.eq(next_event(events), "up raw")
  talking = Task.spawn(&chatter, Chatter(socket: peer))
  sending = Task.spawn(&flood, Flood(node: alpha, body: big_body()))
  outcome = Test.eq(next_event(events, BLOCK_MS), "down raw")
  Task.cancel(talking)
  Task.cancel(sending)
  TCP.close(peer)
  outcome
end

# An event that the watcher has no room for is a drop.
def event_with_no_room_is_dropped(alpha: Cluster.Node) -> Result[Void]
  events: Channel[Cluster.Event] = Channel.new(1)
  try Cluster.watch(alpha, events.address, ->(event) { event })
  peer = try raw_peer(Cluster.port(alpha))
  TCP.close(peer)
  deadline = Time.monotonic_ms() + READ_MS
  while Cluster.dropped(alpha) < 1 and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Test.eq(Cluster.dropped(alpha), 1)
end

def test_a_quiet_link_gets_a_ping() -> Result[Void]
  alpha = node()
  finished(alpha, quiet_link_gets_a_ping(alpha))
end

def test_a_peer_that_goes_silent_is_down_in_three_heartbeats() -> Result[Void]
  alpha = node()
  finished(alpha, silent_peer_is_down(alpha))
end

def test_a_peer_that_answers_pings_is_not_down() -> Result[Void]
  alpha = node()
  finished(alpha, peer_that_answers_stays_up(alpha))
end

def test_a_peer_that_reads_nothing_is_down_even_when_a_send_holds_the_socket() -> Result[Void]
  alpha = node()
  finished(alpha, peer_that_reads_nothing_is_down(alpha))
end

def test_an_event_with_no_room_is_counted_as_a_drop() -> Result[Void]
  alpha = node()
  finished(alpha, event_with_no_room_is_dropped(alpha))
end

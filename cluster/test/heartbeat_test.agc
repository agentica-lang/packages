import Cluster from "../cluster"
import Handshake from "../src/handshake"
import Types from "../src/types"
import Wire from "../src/wire"

private

COOKIE = "the-cookie-of-the-cluster"
HEARTBEAT_MS = 100
READ_MS = 2000
POLL_MS = 10

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

def next_event(events: Channel[Cluster.Event]) -> String
  case events.recv(READ_MS)
    ok(Cluster.Event.NodeUp(name)) -> "up #{name}"
    ok(Cluster.Event.NodeDown(name)) -> "down #{name}"
    error(_) -> "none"
  end
end

def test_a_quiet_link_gets_a_ping() -> Result[Void]
  alpha = node()
  peer = try raw_peer(Cluster.port(alpha))
  frame = try read_frame(peer)
  TCP.close(peer)
  try stopped(alpha)
  Test.eq(frame, Types.Message.Ping)
end

def test_a_peer_that_goes_silent_is_down_in_three_heartbeats() -> Result[Void]
  alpha = node()
  events = watching(alpha)
  peer = try raw_peer(Cluster.port(alpha))
  try Test.eq(next_event(events), "up raw")
  started = Time.monotonic_ms()
  try Test.eq(next_event(events), "down raw")
  waited = Time.monotonic_ms() - started
  TCP.close(peer)
  try stopped(alpha)
  try Test.assert(waited >= 2 * HEARTBEAT_MS, "it was told as down after #{waited} ms, before 2 heartbeats")
  Test.assert(waited <= 20 * HEARTBEAT_MS, "it was told as down after #{waited} ms, long after 3 heartbeats")
end

def test_a_peer_that_answers_pings_is_not_down() -> Result[Void]
  alpha = node()
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
  try Test.eq(next_event(events), "down raw")
  stopped(alpha)
end

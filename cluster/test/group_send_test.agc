import Cluster from "../cluster"
import Handshake from "../src/handshake"
import Types from "../src/types"
import Wire from "../src/wire"

private

COOKIE = "the-cookie-of-the-cluster"
HEARTBEAT_MS = 10_000
READ_MS = 2000
POLL_MS = 10
TRIES = 40

def node() -> Cluster.Node
  Cluster.start(Cluster.Options(name: "alpha", cookie: COOKIE, heartbeat_ms: HEARTBEAT_MS)).unwrap!
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

# A peer written by hand that shakes hands as the client and says that its mailboxes are in the group `workers`. It
# reads nothing, unless the test does.
def raw_member(alpha: Cluster.Node, mailboxes: List[String]) -> Result[TCP.Socket]
  socket = try TCP.connect("127.0.0.1", Cluster.port(alpha), READ_MS)
  nonce = Handshake.fresh_nonce()
  try TCP.send_bytes(socket, Wire.preamble() + try Wire.encode(Types.Message.Hello("raw", nonce)), READ_MS)
  try Wire.check_preamble(try read_exact(socket, 6))
  case try read_frame(socket)
    Types.Message.Challenge(server, server_nonce, server_proof) ->
      session = try Handshake.session("raw", server, nonce, server_nonce)
      proof = try Handshake.answer(COOKIE.bytes, session, server_proof)
      try TCP.send_bytes(socket, try Wire.encode(proof), READ_MS)
      _ = try read_frame(socket)
      try TCP.send_bytes(socket, try says(mailboxes), READ_MS)
      ok(socket)

    _ -> error("the node did not challenge")
  end
end

def says(mailboxes: List[String]) -> Result[Bytes]
  Wire.encode(Types.Message.Groups(1, mailboxes.map { |name| Types.Membership(group: "workers", mailbox: name) }))
end

def members_within(alpha: Cluster.Node, count: Int) -> Bool
  deadline = Time.monotonic_ms() + READ_MS
  while Cluster.group_members(alpha, "workers").unwrap!.size < count and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Cluster.group_members(alpha, "workers").unwrap!.size >= count
end

def big_body() -> Bytes
  chunk = Bytes.from_list((1..1000).map { |_| 7 }).unwrap!
  Bytes.concat((1..900).map { |_| chunk })
end

def mailbox_of(message: Types.Message) -> String
  case message
    Types.Message.Mail(mailbox, _) -> mailbox
    _ -> "not a mail"
  end
end

# The members of one peer are written to its link in the order of the members.
def in_order(alpha: Cluster.Node) -> Result[Void]
  peer = try raw_member(alpha, ["m3", "m1", "m2"])
  try Test.assert(members_within(alpha, 3), "alpha did not hear the members")
  try Test.eq(Cluster.group_send(alpha, "workers", "x".bytes), ok(3))
  first = mailbox_of(try read_frame(peer))
  second = mailbox_of(try read_frame(peer))
  third = mailbox_of(try read_frame(peer))
  TCP.close(peer)
  Test.eq([first, second, third], ["m1", "m2", "m3"])
end

# A peer that reads nothing fills its buffers, and then a write takes the whole time that the call has: it is not
# counted, its link is closed, and the call comes back in about that time.
def silent_peer(alpha: Cluster.Node) -> Result[Void]
  peer = try raw_member(alpha, ["m1"])
  try Test.assert(members_within(alpha, 1), "alpha did not hear the members")
  body = big_body()
  slowest = 0
  last = 1
  tries = 0
  while last > 0 and tries < TRIES
    started = Time.monotonic_ms()
    last = try Cluster.group_send(alpha, "workers", body, 200)
    slowest = [slowest, Time.monotonic_ms() - started].max.unwrap!
    tries += 1
  end

  TCP.close(peer)
  try Test.eq(last, 0)
  Test.assert(slowest < 1500, "a call took #{slowest} ms with a time of 200 ms")
end

# What a test did, and then the node stopped whatever happened, and no task is left.
def finished(before: Int, alpha: Cluster.Node, outcome: Result[Void]) -> Result[Void]
  _ = Cluster.stop(alpha, 1000)
  deadline = Time.monotonic_ms() + READ_MS
  while Task.pending_count() > before and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  try outcome
  Test.eq(Task.pending_count(), before)
end

def test_the_members_of_one_peer_get_the_message_in_order() -> Result[Void]
  before = Task.pending_count()
  alpha = node()
  finished(before, alpha, in_order(alpha))
end

def test_a_peer_that_reads_nothing_costs_one_call_its_time_and_no_task() -> Result[Void]
  before = Task.pending_count()
  alpha = node()
  finished(before, alpha, silent_peer(alpha))
end

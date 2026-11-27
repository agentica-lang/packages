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
def raw_member(alpha: Cluster.Node, name: String, mailboxes: List[String]) -> Result[TCP.Socket]
  socket = try TCP.connect("127.0.0.1", Cluster.port(alpha), READ_MS)
  nonce = Handshake.fresh_nonce()
  try TCP.send_bytes(socket, Wire.preamble() + try Wire.encode(Types.Message.Hello(name, nonce)), READ_MS)
  try Wire.check_preamble(try read_exact(socket, 6))
  case try read_frame(socket)
    Types.Message.Challenge(server, server_nonce, server_proof) ->
      session = try Handshake.session(name, server, nonce, server_nonce)
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

def group_emptied(alpha: Cluster.Node) -> Bool
  deadline = Time.monotonic_ms() + READ_MS
  while not Cluster.group_members(alpha, "workers").unwrap!.empty? and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Cluster.group_members(alpha, "workers").unwrap!.empty?
end

def drain(socket: TCP.Socket) -> Void
  while read_frame(socket).ok?
    nil
  end
end

def body_of(kilobytes: Int) -> Bytes
  chunk = Bytes.from_list((1..1000).map { |_| 7 }).unwrap!
  Bytes.concat((1..kilobytes).map { |_| chunk })
end

def mailbox_of(message: Types.Message) -> String
  case message
    Types.Message.Mail(mailbox, _) -> mailbox
    _ -> "not a mail"
  end
end

# The members of one peer are written to its link in the order of the members.
def in_order(alpha: Cluster.Node) -> Result[Void]
  peer = try raw_member(alpha, "raw", ["m3", "m1", "m2"])
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
  peer = try raw_member(alpha, "raw", ["m1"])
  try Test.assert(members_within(alpha, 1), "alpha did not hear the members")
  body = body_of(900)
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
  try Test.assert(slowest < 1500, "a call took #{slowest} ms with a time of 200 ms")
  # The write that timed out closed the link, so the peer and its members are gone.
  Test.assert(members_within(alpha, 0) and group_emptied(alpha), "the members of the peer are still there")
end

# One peer reads nothing and the other one reads everything: the call is held for the time that it has, by the one that
# is silent, and the healthy peer gets all its messages.
def one_silent_one_healthy(alpha: Cluster.Node) -> Result[Void]
  silent = try raw_member(alpha, "rawa", ["m1"])
  healthy = try raw_member(alpha, "rawb", ["m2"])
  _ = Task.spawn(&drain, healthy)
  try Test.assert(members_within(alpha, 2), "alpha did not hear the members")
  body = body_of(900)
  last = 2
  tries = 0
  while last == 2 and tries < TRIES
    last = try Cluster.group_send(alpha, "workers", body, 200)
    tries += 1
  end

  TCP.close(silent)
  TCP.close(healthy)
  Test.eq(last, 1)
end

# A body that is too big is refused before anything is written: the next message is the first that the peer reads.
def too_large_sends_nothing(alpha: Cluster.Node) -> Result[Void]
  peer = try raw_member(alpha, "raw", ["m1"])
  try Test.assert(members_within(alpha, 1), "alpha did not hear the members")
  big = body_of(2000)
  try Test.eq(Cluster.group_send(alpha, "workers", big).unwrap_or(0), 0)
  try Test.eq(Cluster.group_send(alpha, "workers", "x".bytes), ok(1))
  frame = try read_frame(peer)
  TCP.close(peer)
  Test.eq(frame, Types.Message.Mail("m1", "x".bytes))
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

def test_a_silent_peer_does_not_hold_a_healthy_one() -> Result[Void]
  before = Task.pending_count()
  alpha = node()
  finished(before, alpha, one_silent_one_healthy(alpha))
end

def test_a_body_that_is_too_large_sends_nothing() -> Result[Void]
  before = Task.pending_count()
  alpha = node()
  finished(before, alpha, too_large_sends_nothing(alpha))
end

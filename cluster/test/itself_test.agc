import Cluster from "../cluster"
import Handshake from "../src/handshake"
import Link from "../src/link"
import Types from "../src/types"
import Wire from "../src/wire"

private

COOKIE = "the-cookie-of-the-cluster"
READ_MS = 2000
POLL_MS = 10

# A connection that says hello under the name of the node and the nonce, and reads until the node closes it.
def hello_as(alpha: Cluster.Node, nonce: Bytes) -> Result[Void]
  socket = try TCP.connect("127.0.0.1", Cluster.port(alpha), READ_MS)
  hello = try Wire.encode(Types.Message.Hello("alpha", nonce))
  try TCP.send_bytes(socket, Wire.preamble() + hello, READ_MS)
  read_until_closed(socket)
  TCP.close(socket)
  ok()
end

def read_until_closed(socket: TCP.Socket) -> Void
  case TCP.recv_bytes(socket, 1000, READ_MS)
    ok(bytes) if bytes.size > 0 -> read_until_closed(socket)
    _ -> nil
  end
end

def refused_within(alpha: Cluster.Node, count: Int) -> Int
  deadline = Time.monotonic_ms() + READ_MS
  while Cluster.refused(alpha) < count and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  Cluster.refused(alpha)
end

def node() -> Cluster.Node = Cluster.start(Cluster.Options(name: "alpha", cookie: COOKIE)).unwrap!

def finished(alpha: Cluster.Node, outcome: Result[Void]) -> Result[Void]
  _ = Cluster.stop(alpha, 1000)
  outcome
end

# The nonce of a dial that is running: the node that hears it knows that it dialed itself, and counts nothing.
def a_live_nonce_is_the_node_itself(alpha: Cluster.Node) -> Result[Void]
  nonce = Handshake.fresh_nonce()
  alpha.counts.put(Link.mark(nonce), 0)
  try hello_as(alpha, nonce)
  try Test.eq(alpha.counts.get(Link.mark(nonce)), ok(1))
  Test.eq(Cluster.refused(alpha), 0)
end

# A nonce that no dial of the node made is another node that took the name: it is refused and counted.
def an_unknown_nonce_is_refused(alpha: Cluster.Node) -> Result[Void]
  try hello_as(alpha, Handshake.fresh_nonce())
  Test.eq(refused_within(alpha, 1), 1)
end

def test_a_hello_with_the_name_of_the_node_and_the_nonce_of_a_dial_is_not_counted() -> Result[Void]
  alpha = node()
  finished(alpha, a_live_nonce_is_the_node_itself(alpha))
end

def test_a_hello_with_the_name_of_the_node_and_a_nonce_that_no_dial_made_is_refused() -> Result[Void]
  alpha = node()
  finished(alpha, an_unknown_nonce_is_refused(alpha))
end

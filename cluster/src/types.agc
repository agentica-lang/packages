## The records of the package: what a node says to another one on a connection, and what a node is.

import Actor from "std/actor"

## The kinds of the errors of the package, for `e.is_a?("cluster.protocol")`. Bytes that break the wire format: a bad
## preamble, a length of zero, an unknown kind or a body that does not fit its kind.
PROTOCOL = "cluster.protocol"

## The peer did not prove that it knows the cookie, or it has the name of this node or another name than the one
## that was dialed.
REFUSED = "cluster.refused"

## A bad option, such as a cookie that is too short.
ARGUMENT = "cluster.argument"

## The peer cannot be reached: nothing listens at its address, or the connection did not open in time.
UNREACHABLE = "cluster.unreachable"

## The connection ended or went quiet before the handshake did.
CLOSED = "cluster.closed"

## The key of the table that counts the connections in their handshake.
PENDING = "pending"

## A frame is longer than the limit of the connection.
TOO_LARGE = "cluster.too_large"

## The most bytes of a frame (its kind and its body), when the options say nothing else.
MAX_FRAME_BYTES = 1_048_576

## The most bytes of the name of a mailbox.
MAX_MAILBOX_BYTES = 255

## The most bytes of a frame before the handshake ends. The biggest frame of the handshake has less than 200, so a
## stranger cannot make a node read more before it proves the cookie.
PRE_AUTH_MAX_FRAME_BYTES = 256

## The bytes of a nonce and of a proof (HMAC-SHA256), and the least bytes of a cookie. The least is a floor, not a
## measure of strength: the cookie should be a random secret (`openssl rand -hex 32`).
NONCE_BYTES = 32
PROOF_BYTES = 32
MIN_COOKIE_BYTES = 16

## What a node says: the four messages of the handshake (src/handshake.agc), then ping, pong and bye. A `Mail` goes
## to the mailbox of the receiving node, with the Term CBOR bytes of the value. A frame of a kind that this version
## does not know, but that is meant to be skipped, reads as `Ignored`.
enum Message
  Hello(String, Bytes)
  Challenge(String, Bytes, Bytes)
  Proof(Bytes)
  Welcome
  Ping
  Pong
  Bye(String)
  Mail(String, Bytes)
  Ignored(Int)
end

## A peer read apart: `host:port`, or `name@host:port` when the name of the node is known (src/endpoint.agc).
struct Endpoint
  host: String
  port: Int
  node: String = ""
end

## What a node needs to start. `cookie` is the shared secret (16 bytes at least). `peers` are the `host:port` of the
## nodes to connect to. Plain TCP is only allowed on this machine unless `insecure_plaintext` is true. `connect_ms` is
## the time that a connection has to finish its handshake, and `max_pending` how many connections may be in their
## handshake at once: a new one over that is closed at once.
struct Options
  name: String
  cookie: String
  host: String = "127.0.0.1"
  port: Int = 0
  peers: List[String] = []
  connect_ms: Int = 5000
  max_pending: Int = 128
  max_frame_bytes: Int = 1_048_576
  insecure_plaintext: Bool = false
end

## A node that connected and proved the cookie: the link of its connection, `dialer` is the side that opened it.
struct Peer
  name: String
  dialer: String
  endpoint: String
  link: TaskRef
end

## What the actor of a node hears. `Linked` is a connection that passed the handshake, and its channel gets whether the
## node keeps it. `Dial` opens a connection in a task of the node and answers on its channel with the name of the peer:
## a second `Dial` of an address that is linked or being dialed waits for the same answer. `Dialed` is that answer,
## from the task that dialed, for the address that it dialed.
enum Msg
  Linked(Peer, Channel[Bool])
  Closed(String, Int)
  Dial(Endpoint, Channel[Result[String]])
  Dialed(String, Result[String])
  Refused
  Names(Channel[List[String]])
  Refusals(Channel[Int])
end

## A caller of `connect` that waits for a dial: where the answer goes, and the name that the address must answer under
## (empty when the caller did not say one).
struct Waiter
  reply: Channel[Result[String]]
  name: String
end

## A connection that is being dialed: its task, and the callers that wait for the answer.
struct Dialing
  task: Task[Void]
  waiters: List[Waiter]
end

## The state of the actor of a node: the peers by name, the addresses being dialed, and how many handshakes it refused.
struct State
  config: Config
  peers: Map[String, Peer]
  dialing: Map[String, Dialing]
  refused: Int
end

## What the tasks of a node share: its name, the cookie, the limits, and the table that counts the connections in their
## handshake (`pending`).
struct Config
  name: String
  cookie: Bytes
  connect_ms: Int
  max_pending: Int
  pending: ATS[String, Int]
  max_frame_bytes: Int
  node: Address[Msg]
end

## A running node. `Cluster.start` makes it.
struct Node
  name: String
  port: Int
  connect_ms: Int
  insecure_plaintext: Bool
  actor: Actor.Ref[State, Msg]
  acceptor: Task[Void]
end

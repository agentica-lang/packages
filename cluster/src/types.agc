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
DIALS = "dials"

## The key of the table that counts the messages that the node dropped.
DROPPED = "dropped"

## The peer is not connected now: it never was, or its link ended.
NOT_CONNECTED = "cluster.not_connected"

## A frame is longer than the limit of the connection.
TOO_LARGE = "cluster.too_large"

## The most bytes of a frame (its kind and its body), which is also the most that the options may say: the frame and
## its length of 4 bytes go out in one write of a socket, which takes 1 MiB at most.
MAX_FRAME_BYTES = 1_048_572

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
  Groups(Int, List[Membership])
  Ignored(Int)
end

## A mailbox of a node that joined a group.
struct Membership
  group: String
  mailbox: String
end

## A member of a group: the mailbox `mailbox` of the node `node`.
struct Member
  node: String
  mailbox: String
end

## The writer of a link for the groups of this node: its task, the signal that tells it that `slot` has a newer frame,
## and the slot, which has the newest frame only.
struct Sender
  task: Task[Void]
  signal: Channel[Int]
  slot: ATS[String, Bytes]
end

## What a peer said of its groups: the number of its last change, and all its memberships.
struct Remote
  version: Int
  memberships: List[Membership]
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
## handshake at once: a new one over that is closed at once. `discover` is a `host:port` whose host is a name with the
## addresses of the nodes (the A and AAAA records), which the node looks up every `discover_ms` and dials.
struct Options
  name: String
  cookie: String
  host: String = "127.0.0.1"
  port: Int = 0
  peers: List[String] = []
  discover: String = ""
  discover_ms: Int = 10_000
  connect_ms: Int = 5000
  heartbeat_ms: Int = 1000
  reconnect_ms: Int = 500
  reconnect_max_ms: Int = 30_000
  max_pending: Int = 128
  max_frame_bytes: Int = 1_048_572
  insecure_plaintext: Bool = false
end

## What a node tells those who watch it: a peer is connected (`NodeUp`), or its link ended, because it said bye, the
## socket closed or it went silent (`NodeDown`). The name is the one of the peer.
enum Event
  NodeUp(String)
  NodeDown(String)
end

## A node that connected and proved the cookie: the link of its connection, `dialer` is the side that opened it.
struct Peer
  name: String
  dialer: String
  endpoint: String
  link: TaskRef
  socket: TCP.Socket
end

## A message that a peer sent to a mailbox of this node: the name of the peer, the mailbox and the bytes that the peer
## wrote (the `Term.encode` of a value, which the receiver decodes into its own type).
struct Delivery
  from: String
  mailbox: String
  body: Bytes
end

## What the actor of a node hears. `Linked` is a connection that passed the handshake, and its channel gets whether
## the node keeps it. `Dial` opens a connection in a task of the node and answers on its channel with the name of the
## peer: a second `Dial` of an address that is linked or being dialed waits for the same answer. `Dialed` is that
## answer, from the task that dialed, for the address that it dialed. `Found` is the whole answer of a lookup of the
## name, and `Own` the address of a dial that reached the node itself.
enum Msg
  Linked(Peer, Channel[Bool])
  Closed(String, Int)
  Dial(Endpoint, Channel[Result[String]])
  Dialed(String, Result[String])
  Refused
  Names(Channel[List[String]])
  Refusals(Channel[Int])
  Deliver(String, String, Bytes)
  Register(String, Fn[Delivery, Bool], Channel[Bool])
  Route(String, Channel[Optional[TCP.Socket]])
  Watch(Fn[Event, Bool], Channel[Bool])
  Keep(List[Endpoint])
  Discover(Endpoint)
  Found(List[Endpoint])
  Join(String, String, Channel[Result[Void]])
  Leave(String, String, Channel[Bool])
  Members(String, Channel[List[Member]])
  Groups(String, Int, List[Membership])
  Own(String)
  Redial(String)
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
## `kept` are the peers of the list (`names` has the name that answers at each address, once it is known), which the
## node dials again when a dial fails or a link of the peer ends: `delays` is the last wait for each one (it grows
## until `reconnect_max_ms`, and starts over when a link is kept) and `timers` are the waits that are running. `own`
## are the addresses where a dial reached this very node, with the time (`Time.monotonic_ms`) until which they are left
## alone. `groups` are the memberships of this node and `version` counts their changes; `remote` has what each peer
## said of its own, until its link ends, and `senders` the writer of each link.
struct State
  config: Config
  peers: Map[String, Peer]
  dialing: Map[String, Dialing]
  mailboxes: Map[String, Fn[Delivery, Bool]]
  watchers: List[Fn[Event, Bool]]
  kept: Map[String, Endpoint]
  found: Map[String, Endpoint]
  finders: List[Task[Void]]
  names: Map[String, String]
  own: Map[String, Int]
  groups: List[Membership]
  version: Int
  remote: Map[String, Remote]
  senders: Map[String, Sender]
  delays: Map[String, Int]
  timers: Map[String, Task[Void]]
  refused: Int
end

## What the tasks of a node share: its name, the cookie, the limits, and `counts`, the table that the tasks of the node
## add to: the connections in their handshake (`PENDING`) and the messages dropped (`DROPPED`).
struct Config
  name: String
  cookie: Bytes
  connect_ms: Int
  heartbeat_ms: Int
  discover_ms: Int
  reconnect_ms: Int
  reconnect_max_ms: Int
  max_pending: Int
  counts: ATS[String, Int]
  max_frame_bytes: Int
  node: Address[Msg]
end

## A running node. `Cluster.start` makes it.
struct Node
  name: String
  port: Int
  connect_ms: Int
  max_frame_bytes: Int
  insecure_plaintext: Bool
  counts: ATS[String, Int]
  actor: Actor.Ref[State, Msg]
  acceptor: Task[Void]
end

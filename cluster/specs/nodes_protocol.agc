## The requests that the step program (`nodes_steps.agc`) sends to the driver (`driver.agc`), one JSON line each. The
## driver holds the nodes, since a step program cannot keep tasks between its steps, and answers every request with one
## line: `ok`, or the reason that it failed.

## The reply that means the request worked.
OK = "ok"

## A node to start. `dials` are the names of nodes that already run: the new node has their addresses in its list of
## peers, written `name@host:port` when `named` is true, and `addresses` are more peers written as they are.
## `host` is where it listens.
struct Spec
  name: String
  cookie: String
  dials: List[String] = []
  addresses: List[String] = []
  named: Bool = false
  host: String = "127.0.0.1"
  connect_ms: Int = 5000
  max_pending: Int = 128
  heartbeat_ms: Int = 1000
  reconnect_ms: Int = 500
  reconnect_max_ms: Int = 0
  discover: String = ""
  discover_port_of: String = ""
  discover_ms: Int = 10_000
  insecure: Bool = false
  again: Bool = false
  max_frame_bytes: Int = 1_048_572
end

## One node connects to another and the answer must be `ok` (`kind` is `""`) or an error of that kind. `as_name` is a
## name that differs from the real one of the node (so that the connection expects a node that is not there), and
## `address` replaces the address of `to`.
struct Connect
  from: String
  to: String
  kind: String = ""
  as_name: String = ""
  address: String = ""
end

## What a node must know within `within_ms`: exactly these peers, and again after `hold_ms` more.
struct Peers
  node: String
  names: List[String]
  within_ms: Int
  hold_ms: Int = 0
end

## How many handshakes a node must have refused within `within_ms`.
struct Refusals
  node: String
  count: Int
  within_ms: Int
end

## What a stranger writes to a node on a plain socket, and the node must close the connection within `within_ms`:
## `Text` is sent as it is, `Big` is the preamble and a frame that says it has this many bytes, `Ping` is the preamble
## and a ping (a frame that is not allowed before the handshake ends), `Silence` writes nothing, and `WrongProof`
## shakes hands as far as a proof that it makes up, and then the node must close with nothing more said.
enum Stranger
  Text(String)
  Big(Int)
  Ping
  Silence
  WrongProof
end

struct Visit
  node: String
  stranger: Stranger
  within_ms: Int
end

## A connection that a node makes to a hole (a listener that accepts and never answers), and the time it may take.
struct HoleVisit
  from: String
  hole: String
  kind: String = ""
  within_ms: Int = 0
end

## `count` strangers connect to a node and say nothing: `closed` of them must be closed at once, the others left alone.
struct Flood
  node: String
  count: Int
  closed: Int
end

## What a step sends to a mailbox: the `Term.encode` of a job (an `id` and a `name`), 100 jobs one after the other,
## bytes that are not CBOR, the CBOR of a type that is not a job, or `size` bytes of CBOR.
enum Payload
  Job(Int, String)
  Jobs(Int)
  Garbage(String)
  Other
  Big(Int)
end

struct Post
  from: String
  to: String
  mailbox: String
  payload: Payload
  kind: String = ""
  timeout_ms: Int = 5000
end

## A node registers a mailbox, and the driver decodes what comes into it as a job and keeps one line for each message.
struct Mailbox
  node: String
  name: String
  capacity: Int = 1000
  reading: Bool = true
end

## What the mailbox must have received within `within_ms`, in order (`lines`, in the text of `Collected`).
struct Received
  node: String
  mailbox: String
  lines: List[String]
  within_ms: Int
  last_only: Bool = false
end

## How many messages a node must have dropped within `within_ms`.
struct Drops
  node: String
  count: Int
  within_ms: Int
end

## A mailbox of a node that joins or leaves a group.
struct Joining
  node: String
  group: String
  mailbox: String
end

## The members that a node must see in a group within `within_ms`, each as `node/mailbox`.
struct Expected
  node: String
  group: String
  members: List[String]
  within_ms: Int
end

## A message to a group: how many members it must reach, or the kind of the error that it must fail with.
struct GroupPost
  from: String
  group: String
  payload: Payload
  reached: Int = 0
  kind: String = ""
end

enum Request
  Start(Spec)
  StartFails(Spec, String)
  Connect(Connect)
  ConnectBoth(String, String)
  Peers(Peers)
  Refusals(Refusals)
  Stop(String)
  Visit(Visit)
  Hole(String)
  ConnectHole(HoleVisit)
  ConnectLater(HoleVisit)
  ConnectTwice(String, String)
  StopWithin(String, Int)
  Flood(Flood)
  Register(Mailbox)
  Post(Post)
  Received(Received)
  InOrder(String, String, Int, Int)
  Drops(Drops)
  RegisterFails(Mailbox, String)
  ReplacedEmpty(String, String)
  Watch(String)
  Join(Joining)
  JoinFails(Joining, String)
  Leave(Joining)
  Members(Expected)
  GroupPost(GroupPost)
end

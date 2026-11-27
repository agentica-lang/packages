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

enum Request
  Start(Spec)
  StartFails(Spec, String)
  Connect(Connect)
  ConnectBoth(String, String)
  Peers(Peers)
  Refusals(Refusals)
  Stop(String)
  Visit(Visit)
end

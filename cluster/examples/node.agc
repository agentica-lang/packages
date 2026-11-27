## One node of a small cluster, to try the package by hand. It is set by environment variables (the default of each is
## in `settings`): `NODE_NAME`, `CLUSTER_COOKIE`, `NODE_HOST`, `NODE_PORT`, `PEERS` (a list of `name@host:port` or
## `host:port` separated by commas), `INSECURE` (`1` for a host that is not this machine: no TLS yet, so a network that
## you trust), `DISCOVER` (a `host:port` whose host is a name with the addresses of the nodes, looked up every
## `DISCOVER_MS`, 10000 by default), `NAME_FROM_HOSTNAME` (`1`: the node is called `node-` and the host name, so that
## the replicas of a service have a name each) and `RUN_SECONDS` (0: until it is stopped). It prints when a peer comes and goes, and greets each peer
## once every `GREET_MS`.
##
##   NODE_NAME=alpha NODE_PORT=7001 PEERS=beta@127.0.0.1:7002 agentica examples/node.agc
##   NODE_NAME=beta NODE_PORT=7002 PEERS=alpha@127.0.0.1:7001 agentica examples/node.agc
##
## Stop one of them and the other prints `node_down`; start it again and it prints `node_up`.

import Cluster from "../cluster"

struct Greeting
  from: String
  count: Int
end

struct Settings
  name: String
  cookie: String
  host: String
  port: Int
  peers: List[String]
  insecure: Bool
  discover: String
  discover_ms: Int
  run_ms: Int
end

# What the node hears: an event of a peer, or a greeting.
enum Note
  Event(Cluster.Event)
  Mail(Cluster.Delivery)
end

struct Greeter
  node: Cluster.Node
  me: String
end

def main() -> Void
  settings = read_settings()
  options = Cluster.Options(
    name: settings.name,
    cookie: settings.cookie,
    host: settings.host,
    port: settings.port,
    peers: settings.peers,
    insecure_plaintext: settings.insecure,
    reconnect_ms: RECONNECT_MS,
    reconnect_max_ms: 5000,
    heartbeat_ms: HEARTBEAT_MS,
    discover: settings.discover,
    discover_ms: settings.discover_ms,
  )

  case Cluster.start(options)
    error(e) -> IO.warn("#{settings.name}: #{e.message}")
    ok(node) -> run(node, settings)
  end
end

private

GREET_MS = 2000
HEARTBEAT_MS = 500
RECONNECT_MS = 200
TICK_MS = 500

def env(name: String, default: String) -> String = System.env(name).unwrap_or(default)

def node_name() -> String
  return "node-#{env("HOSTNAME", "alpha").downcase}" if env("NAME_FROM_HOSTNAME", "") == "1"

  env("NODE_NAME", "alpha")
end

def read_settings() -> Settings
  peers = env("PEERS", "").split(",").map { |peer| peer.strip }.select { |peer| not peer.empty? }
  Settings(
    name: node_name(),
    cookie: env("CLUSTER_COOKIE", "an-example-cookie-of-16-bytes-or-more"),
    host: env("NODE_HOST", "127.0.0.1"),
    port: env("NODE_PORT", "0").to_i.unwrap_or(0),
    peers: peers,
    insecure: env("INSECURE", "") == "1",
    discover: env("DISCOVER", ""),
    discover_ms: env("DISCOVER_MS", "10000").to_i.unwrap_or(10_000),
    run_ms: env("RUN_SECONDS", "0").to_i.unwrap_or(0) * 1000,
  )
end

def run(node: Cluster.Node, settings: Settings) -> Void
  notes: Channel[Note] = Channel.new(64)
  _ = Cluster.watch(node, notes.address, ->(event) { Note.Event(event) })
  _ = Cluster.register(node, "greetings", notes.address, ->(delivery) { Note.Mail(delivery) })
  puts("#{settings.name} listens on #{settings.host}:#{Cluster.port(node)}")
  _ = Task.spawn(&greet, Greeter(node: node, me: settings.name))
  listen(node, notes, settings)
  _ = Cluster.stop(node, 1000)
end

# Prints what happens until the time is up (never, when it is 0).
def listen(node: Cluster.Node, notes: Channel[Note], settings: Settings) -> Void
  deadline = Time.monotonic_ms() + settings.run_ms
  refused = 0
  while settings.run_ms == 0 or Time.monotonic_ms() < deadline
    if Cluster.refused(node) != refused
      refused = Cluster.refused(node)
      puts("#{settings.name}: refused #{refused} handshakes, the cookie or a name is wrong")
    end

    case notes.recv(TICK_MS)
      ok(Note.Event(Cluster.Event.NodeUp(peer))) -> puts("#{settings.name}: node_up #{peer}")
      ok(Note.Event(Cluster.Event.NodeDown(peer))) -> puts("#{settings.name}: node_down #{peer}")
      ok(Note.Mail(delivery)) -> puts("#{settings.name}: #{describe(delivery)}")
      error(_) -> nil
    end
  end
end

def describe(delivery: Cluster.Delivery) -> String
  case Term.decode(delivery.body, Greeting)
    ok(greeting) -> "hello from #{greeting.from} (#{greeting.count})"
    error(_) -> "a message from #{delivery.from} that is not a greeting"
  end
end

# Every `GREET_MS`, a greeting to each peer that is connected.
def greet(greeter: Greeter) -> Void
  count = 0
  while true
    Task.sleep(GREET_MS)
    count += 1
    body = Term.encode(Greeting(from: greeter.me, count: count)).unwrap!
    for peer in Cluster.nodes(greeter.node)
      _ = Cluster.send(greeter.node, peer, "greetings", body)
    end
  end
end

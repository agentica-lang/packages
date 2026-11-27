## The program under test of nodes.feature: it holds the nodes, runs the requests of `nodes_protocol.agc` that the
## steps send (one JSON line in, one reply line out), and answers `ok` or why not. Every node of a scenario lives here,
## as the nodes of a cluster would in their own processes, on 127.0.0.1 with a port that the system picks.

import Binary from "std/binary"
import Cluster from "../cluster"
import Protocol from "nodes_protocol"
import {Connect, Flood, HoleVisit, Peers, Refusals, Request, Spec, Stranger, Visit} from "nodes_protocol"
import Types from "../src/types"
import Wire from "../src/wire"

def main() -> Void
  nodes: Map[String, Cluster.Node] = {}
  holes: ATS[String, Int] = ATS.new()
  line = IO.gets
  while line.ok?
    reply = Protocol.OK
    case JSON.decode(line.unwrap_or(""), Request)
      error(e) -> reply = "bad request: #{e.message}"
      ok(request) ->
        handled = act(nodes, holes, request)
        nodes = handled.nodes
        reply = handled.reply
    end

    puts(reply)
    IO.flush()
    line = IO.gets
  end
end

private

POLL_MS = 20
SETTLE_MS = 300
HOLE_ACCEPT_MS = 1000
# A read that ends this close to the deadline timed out; one that ends before it was a connection that ended.
TIMEOUT_SLACK_MS = 100
STOP_MS = 2000
PREAMBLE_MS = 3000
# The preamble and the challenge of a node named `alpha`, which the wrong-proof stranger reads.
CHALLENGE_BYTES = 6 + 4 + 93
LISTEN_HOST = "127.0.0.1"

struct Handled
  nodes: Map[String, Cluster.Node]
  reply: String
end

# What one side of a connection does when both sides connect at the same moment.
struct Side
  node: Cluster.Node
  address: String
end

def done(nodes: Map[String, Cluster.Node]) -> Handled = Handled(nodes: nodes, reply: Protocol.OK)

def failed(nodes: Map[String, Cluster.Node], reply: String) -> Handled = Handled(nodes: nodes, reply: reply)

def act(nodes: Map[String, Cluster.Node], holes: ATS[String, Int], request: Request) -> Handled
  case request
    Request.Start(spec) -> start(nodes, spec)
    Request.StartFails(spec, kind) -> start_fails(nodes, spec, kind)
    Request.Connect(connect) -> failed_or_done(nodes, connect_once(nodes, connect))
    Request.ConnectBoth(a, b) -> failed_or_done(nodes, connect_both(nodes, a, b))
    Request.Peers(peers) -> failed_or_done(nodes, expect_peers(nodes, peers))
    Request.Refusals(refusals) -> failed_or_done(nodes, expect_refusals(nodes, refusals))
    Request.Stop(name) -> stop(nodes, name)
    Request.Visit(visit) -> failed_or_done(nodes, visited(nodes, visit))
    Request.Hole(name) -> failed_or_done(nodes, open_hole(holes, name))
    Request.ConnectHole(visit) -> failed_or_done(nodes, connect_hole(nodes, holes, visit))
    Request.ConnectLater(visit) -> failed_or_done(nodes, connect_later(nodes, holes, visit))
    Request.ConnectTwice(from, to) -> failed_or_done(nodes, connect_twice(nodes, from, to))
    Request.StopWithin(name, within_ms) -> failed_or_done(nodes, stop_within(nodes, name, within_ms))
    Request.Flood(flood) -> failed_or_done(nodes, flooded(nodes, flood))
  end
end

def failed_or_done(nodes: Map[String, Cluster.Node], outcome: String) -> Handled
  Handled(nodes: nodes, reply: outcome)
end

def options_of(nodes: Map[String, Cluster.Node], spec: Spec) -> Cluster.Options
  Cluster.Options(
    name: spec.name,
    cookie: spec.cookie,
    host: spec.host,
    peers: spec.dials.map { |name| address_of(nodes, name, spec.named) } + spec.addresses,
    connect_ms: spec.connect_ms,
    max_pending: spec.max_pending,
  )
end

def address_of(nodes: Map[String, Cluster.Node], name: String, named: Bool) -> String
  port = Cluster.port(nodes[name])
  return "#{name}@127.0.0.1:#{port}" if named

  "127.0.0.1:#{port}"
end

def start(nodes: Map[String, Cluster.Node], spec: Spec) -> Handled
  case Cluster.start(options_of(nodes, spec))
    ok(node) -> done(nodes.put(spec.name, node))
    error(e) -> failed(nodes, "the node did not start: #{e.message}")
  end
end

def start_fails(nodes: Map[String, Cluster.Node], spec: Spec, kind: String) -> Handled
  case Cluster.start(options_of(nodes, spec))
    ok(_) -> failed(nodes, "the node started and it should not have")
    error(e) ->
      if e.is_a?(kind)
        done(nodes)
      else
        failed(nodes, "the start failed with #{e.kind} and not #{kind}")
      end
  end
end

def stop(nodes: Map[String, Cluster.Node], name: String) -> Handled
  _ = Cluster.stop(nodes[name], STOP_MS)
  done(nodes.delete(name))
end

def connect_once(nodes: Map[String, Cluster.Node], connect: Connect) -> String
  target = address_of(nodes, connect.to, false)
  if not connect.as_name.empty?
    target = "#{connect.as_name}@127.0.0.1:#{Cluster.port(nodes[connect.to])}"
  end

  if not connect.address.empty?
    target = connect.address
  end

  verdict(Cluster.connect(nodes[connect.from], target), connect.kind)
end

# The reply of a step that expects `ok` (a kind of `""`) or an error of that kind.
def verdict(result: Result[String], kind: String) -> String
  case result
    ok(name) -> connected_reply(name, kind)
    error(e) -> failed_reply(e, kind)
  end
end

def connected_reply(name: String, kind: String) -> String
  return Protocol.OK if kind.empty?

  "connected to #{name}, and it should have failed with #{kind}"
end

def failed_reply(e: Error, kind: String) -> String
  return Protocol.OK if not kind.empty? and e.is_a?(kind)

  "failed with #{e.kind}"
end

def connect_side(side: Side) -> Result[String] = Cluster.connect(side.node, side.address)

def connect_both(nodes: Map[String, Cluster.Node], a: String, b: String) -> String
  first = Task.spawn(&connect_side, Side(node: nodes[a], address: address_of(nodes, b, false)))
  second = Task.spawn(&connect_side, Side(node: nodes[b], address: address_of(nodes, a, false)))
  from_first = verdict(Task.await(first), "")
  from_second = verdict(Task.await(second), "")
  return from_first if from_first != Protocol.OK

  from_second
end

def expect_peers(nodes: Map[String, Cluster.Node], peers: Peers) -> String
  node = nodes[peers.node]
  deadline = Time.monotonic_ms() + peers.within_ms
  while Cluster.nodes(node) != peers.names and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  return "#{peers.node} has #{Cluster.nodes(node)}" if Cluster.nodes(node) != peers.names

  hold_until = Time.monotonic_ms() + peers.hold_ms
  while Time.monotonic_ms() < hold_until
    return "#{peers.node} then had #{Cluster.nodes(node)}" if Cluster.nodes(node) != peers.names

    Task.sleep(POLL_MS)
  end

  Protocol.OK
end

def expect_refusals(nodes: Map[String, Cluster.Node], refusals: Refusals) -> String
  node = nodes[refusals.node]
  deadline = Time.monotonic_ms() + refusals.within_ms
  while Cluster.refused(node) != refusals.count and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
  end

  return "#{refusals.node} refused #{Cluster.refused(node)}" if Cluster.refused(node) != refusals.count

  Protocol.OK
end

# The stranger writes its bytes on a plain socket and reads until the node closes it.
def visited(nodes: Map[String, Cluster.Node], visit: Visit) -> String
  port = Cluster.port(nodes[visit.node])
  case TCP.connect(LISTEN_HOST, port, PREAMBLE_MS)
    error(e) -> "the stranger could not connect: #{e.message}"
    ok(socket) -> visiting(socket, visit)
  end
end

def visiting(socket: TCP.Socket, visit: Visit) -> String
  case visit.stranger
    Stranger.WrongProof -> wrong_proof(socket, visit.within_ms)
    _ -> closed_within(socket, written(visit.stranger), visit.within_ms)
  end
end

# The stranger says hello, reads the preamble and the challenge, answers with a proof of random bytes, and then the
# node must close the connection and say nothing more.
def wrong_proof(socket: TCP.Socket, within_ms: Int) -> String
  nonce = OpenSSL.Random.random_bytes(Types.NONCE_BYTES)
  hello = Wire.encode(Types.Message.Hello("stranger", nonce)).unwrap!
  _ = TCP.send_bytes(socket, Wire.preamble() + hello, PREAMBLE_MS)
  said = read_to_end(socket, within_ms, CHALLENGE_BYTES)
  proof = Wire.encode(Types.Message.Proof(OpenSSL.Random.random_bytes(Types.PROOF_BYTES))).unwrap!
  _ = TCP.send_bytes(socket, proof, PREAMBLE_MS)
  more = read_to_end(socket, within_ms, 0)
  TCP.close(socket)
  return "the node said #{more.size} bytes after a wrong proof" if not more.empty?
  return "the node did not send a challenge" if said.size < CHALLENGE_BYTES

  Protocol.OK
end

# What the node wrote, until it has `stop_at` bytes (0: until it closes) or `within_ms` passed.
def read_to_end(socket: TCP.Socket, within_ms: Int, stop_at: Int) -> Bytes
  deadline = Time.monotonic_ms() + within_ms
  got = "".bytes
  open = true
  while open and Time.monotonic_ms() < deadline and (stop_at == 0 or got.size < stop_at)
    case TCP.recv_bytes(socket, 1024, deadline - Time.monotonic_ms())
      ok(more) ->
        got = got + more
        open = not more.empty?

      error(_) -> open = false
    end
  end

  got
end

def written(stranger: Stranger) -> Bytes
  case stranger
    Stranger.Text(text) -> text.bytes
    Stranger.Big(size) -> Wire.preamble() + Binary.write_u32_be(size.to_uint32!)
    Stranger.Ping -> Wire.preamble() + Wire.encode(Types.Message.Ping).unwrap!
    Stranger.Silence -> "".bytes
    Stranger.WrongProof -> "".bytes
  end
end

def closed_within(socket: TCP.Socket, bytes: Bytes, within_ms: Int) -> String
  if not bytes.empty?
    _ = TCP.send_bytes(socket, bytes, PREAMBLE_MS)
  end

  deadline = Time.monotonic_ms() + within_ms
  open = true
  while open and Time.monotonic_ms() < deadline
    case TCP.recv_bytes(socket, 1024, deadline - Time.monotonic_ms())
      ok(got) -> open = not got.empty?
      error(_) -> open = Time.monotonic_ms() >= deadline - TIMEOUT_SLACK_MS
    end
  end

  TCP.close(socket)
  return Protocol.OK if not open

  "the node did not close the connection within #{within_ms} ms"
end

# A listener that accepts connections and never says a word, as a node that hangs. The task that accepts owns the
# sockets, so they stay open for the run.
def open_hole(holes: ATS[String, Int], name: String) -> String
  case TCP.listen(LISTEN_HOST, 0)
    error(e) -> "the hole did not open: #{e.message}"
    ok(listener) ->
      holes.put(name, TCP.local_port(listener))
      _ = Task.spawn(&swallow, listener)
      Protocol.OK
  end
end

def swallow(listener: TCP.Listener) -> Void
  while true
    _ = TCP.accept(listener, HOLE_ACCEPT_MS)
  end
end

def hole_address(holes: ATS[String, Int], name: String) -> String = "127.0.0.1:#{holes.get(name).unwrap_or(0)}"

def connect_hole(nodes: Map[String, Cluster.Node], holes: ATS[String, Int], visit: HoleVisit) -> String
  started = Time.monotonic_ms()
  outcome = verdict(Cluster.connect(nodes[visit.from], hole_address(holes, visit.hole)), visit.kind)
  elapsed = Time.monotonic_ms() - started
  return outcome if outcome != Protocol.OK
  if elapsed > visit.within_ms
    return "the connection took #{elapsed} ms, and it should take #{visit.within_ms} at most"
  end

  Protocol.OK
end

# The connection starts and the step goes on; the node is told to stop while it is still waiting.
def connect_later(nodes: Map[String, Cluster.Node], holes: ATS[String, Int], visit: HoleVisit) -> String
  _ = Task.spawn(&connect_side, Side(node: nodes[visit.from], address: hole_address(holes, visit.hole)))
  Task.sleep(SETTLE_MS)
  Protocol.OK
end

# Two callers connect to the same address at once: both get the name of the peer, and there is one link.
def connect_twice(nodes: Map[String, Cluster.Node], from: String, to: String) -> String
  address = address_of(nodes, to, false)
  first = Task.spawn(&connect_side, Side(node: nodes[from], address: address))
  second = Task.spawn(&connect_side, Side(node: nodes[from], address: address))
  from_first = verdict(Task.await(first), "")
  from_second = verdict(Task.await(second), "")
  return from_first if from_first != Protocol.OK

  from_second
end

def stop_within(nodes: Map[String, Cluster.Node], name: String, within_ms: Int) -> String
  started = Time.monotonic_ms()
  stopped = Cluster.stop(nodes[name], STOP_MS)
  elapsed = Time.monotonic_ms() - started
  return "stop failed: #{stopped}" if not stopped.ok?
  return "stop took #{elapsed} ms, and it should take #{within_ms} at most" if elapsed > within_ms

  Protocol.OK
end

# The strangers say nothing. A node that accepts one writes its preamble at once, so a socket that reads nothing
# but the
# end of the connection was closed by the node.
def flooded(nodes: Map[String, Cluster.Node], flood: Flood) -> String
  port = Cluster.port(nodes[flood.node])
  sockets: List[TCP.Socket] = []
  for _ in 1..flood.count
    sockets = sockets.push(TCP.connect(LISTEN_HOST, port, PREAMBLE_MS).unwrap!)
  end

  Task.sleep(SETTLE_MS)
  closed = 0
  for socket in sockets
    if closed_by_node?(socket)
      closed += 1
    end
  end

  for socket in sockets
    TCP.close(socket)
  end

  return "#{closed} connections were closed, and it should be #{flood.closed}" if closed != flood.closed

  Protocol.OK
end

def closed_by_node?(socket: TCP.Socket) -> Bool
  case TCP.recv_bytes(socket, 1, SETTLE_MS)
    ok(got) -> got.empty?
    error(_) -> false
  end
end

## One connection of a node, in the task that owns its socket: the handshake (as the side that dials or the side that
## accepts), then the reading of frames until the connection ends. The node hears of it through its address.
##
## The handshake follows docs/protocol.md: each frame must be the next one, a frame is at most 256 bytes until the
## welcome, the whole handshake has a deadline, and a node that fails it is disconnected with no frame said.

import Actor from "std/actor"
import Endpoint from "endpoint"
import Handshake from "handshake"
import Types from "types"
import Wire from "wire"

## What a task that dials needs: the configuration of the node and where to connect. The task tells the node what came
## of it, which answers the callers that wait.
struct Dial
  config: Types.Config
  endpoint: Types.Endpoint
end

## What a task that accepts gets: the socket (which it owns) and the configuration of the node.
struct Served
  config: Types.Config
  socket: TCP.Socket
end

## What a task that waits to dial a peer of the list again needs.
struct Redial
  node: Address[Types.Msg]
  key: String
  wait_ms: Int
end

## Dials, shakes hands as the client and, once the node keeps the link, reads it until it ends. The connect and the
## handshake share one deadline, `connect_ms` from the start.
def dial(args: Dial) -> Void
  config = args.config
  endpoint = args.endpoint
  deadline = Time.monotonic_ms() + config.connect_ms
  case TCP.connect(endpoint.host, endpoint.port, config.connect_ms)
    error(_) -> fail(args, error("cluster: no node answers at the address", kind: Types.UNREACHABLE))
    ok(socket) -> run_client(args, socket, deadline)
  end
end

## Waits, and tells the node that it is time to dial the address `key` again.
def redial(args: Redial) -> Void
  Task.sleep(args.wait_ms)
  _ = Actor.cast(args.node, Types.Msg.Redial(args.key))
end

## Shakes hands as the server and, once the node keeps the link, reads it until it ends.
def serve(served: Served) -> Void
  config = served.config
  socket = served.socket
  result = server_handshake(config, socket, Time.monotonic_ms() + config.connect_ms)
  _ = config.counts.add(Types.PENDING, -1)
  case result
    error(e) -> refuse(config, socket, e)
    ok(peer) -> run_link(config, socket, peer)
  end
end

private

REGISTER_MS = 5000
SILENT_HEARTBEATS = 3
SEEN = "seen"
DIAL = "dial:"
ITSELF = 1
PREAMBLE_BYTES = 6
HEADER_BYTES = 4

## What the task that watches a link needs: the socket, and when the reader last heard something (`seen`).
struct Watch
  config: Types.Config
  socket: TCP.Socket
  seen: ATS[String, Int]
end

def fail(args: Dial, result: Result[String]) -> Void
  _ = Actor.cast(args.config.node, Types.Msg.Dialed(Endpoint.key(args.endpoint), result))
  if kind_of(result) == Types.REFUSED
    _ = Actor.cast(args.config.node, Types.Msg.Refused)
  end
end

def kind_of(result: Result[String]) -> String
  case result
    ok(_) -> ""
    error(e) -> e.kind
  end
end

def run_client(args: Dial, socket: TCP.Socket, deadline: Int) -> Void
  config = args.config
  nonce = Handshake.fresh_nonce()
  mark = "#{DIAL}#{OpenSSL.Digest.hexencode(nonce)}"
  config.counts.put(mark, 0)
  handshake = client_handshake(config, socket, args.endpoint, deadline, nonce)
  itself = config.counts.get(mark).unwrap_or(0) == ITSELF
  config.counts.delete(mark)
  case handshake
    error(e) ->
      TCP.close(socket)
      if itself
        _ = Actor.cast(config.node, Types.Msg.Own(Endpoint.key(args.endpoint)))
      end

      fail(args, error(e.message, kind: e.kind))

    ok(peer) ->
      kept = register(config, peer)
      _ = Actor.cast(config.node, Types.Msg.Dialed(Endpoint.key(args.endpoint), ok(peer.name)))
      if kept
        keep_reading(config, socket, peer)
      else
        TCP.close(socket)
      end
  end
end

def run_link(config: Types.Config, socket: TCP.Socket, peer: Types.Peer) -> Void
  if register(config, peer)
    keep_reading(config, socket, peer)
  else
    TCP.close(socket)
  end
end

# The socket closes with no frame said, so a wrong guess learns nothing. A count is kept for a node that failed the
# cookie or the names, not for bytes that never were a handshake.
def refuse(config: Types.Config, socket: TCP.Socket, e: Error) -> Void
  if e.is_a?(Types.REFUSED)
    _ = Actor.cast(config.node, Types.Msg.Refused)
  end

  TCP.close(socket)
end

# Whether the node keeps this link: it may already have another link to the same peer (a connection of the same two
# nodes made at the same moment from both sides).
def register(config: Types.Config, peer: Types.Peer) -> Bool
  reply: Channel[Bool] = Channel.new(1)
  case Actor.cast(config.node, Types.Msg.Linked(peer, reply))
    ok(_) ->
      case reply.recv(REGISTER_MS)
        ok(kept) -> kept
        error(_) -> false
      end

    error(_) -> false
  end
end

# After the welcome a link is read: a bye ends it, a mail goes to the node, a ping is answered with a pong and
# any other
# frame is ignored. A task beside the reader (`watch_link`) pings a quiet link and closes a silent one, which ends the
# read. Every chunk that arrives is a sign of life, so a link that carries mail needs no ping, and a big frame that
# comes slowly is not silence.
def keep_reading(config: Types.Config, socket: TCP.Socket, peer: Types.Peer) -> Void
  seen: ATS[String, Int] = ATS.new()
  seen.put(SEEN, Time.monotonic_ms())
  watcher = Task.spawn(&watch_link, Watch(config: config, socket: socket, seen: seen))
  reading = true
  while reading
    case read_message(socket, config.max_frame_bytes, 0, some(seen))
      ok(Types.Message.Bye(_)) -> reading = false
      ok(Types.Message.Mail(mailbox, body)) -> deliver(config, peer, mailbox, body)
      ok(Types.Message.Ping) -> pong(socket, config)
      ok(_) -> nil
      error(_) -> reading = false
    end
  end

  Task.cancel(watcher)
  TCP.close(socket)
  _ = Actor.cast(config.node, Types.Msg.Closed(peer.name, peer.link.id))
end

# Every heartbeat: a link that was quiet for half of one gets a ping, and one that was silent for 3 closes. A read that
# times out would close the socket as well, so the reader waits with no limit and this task does the timing. A ping
# that cannot be written (a big send holds the socket, or the peer does not read) ends the link as well, so that no
# link is left with nobody to watch it.
def watch_link(watch: Watch) -> Void
  config = watch.config
  alive = true
  while alive
    Task.sleep(config.heartbeat_ms)
    silent = Time.monotonic_ms() - watch.seen.get(SEEN).unwrap_or(0)
    if silent > SILENT_HEARTBEATS * config.heartbeat_ms or (silent * 2 >= config.heartbeat_ms and not ping(watch))
      TCP.close(watch.socket)
      alive = false
    end
  end
end

def ping(watch: Watch) -> Bool
  case Wire.encode(Types.Message.Ping)
    ok(frame) -> TCP.send_bytes(watch.socket, frame, SILENT_HEARTBEATS * watch.config.heartbeat_ms).ok?
    error(_) -> false
  end
end

# A pong that cannot be written is not the end of the link (a big send may hold the socket): the watcher decides.
def pong(socket: TCP.Socket, config: Types.Config) -> Void
  case Wire.encode(Types.Message.Pong)
    ok(frame) -> _ = TCP.send_bytes(socket, frame, SILENT_HEARTBEATS * config.heartbeat_ms)
    error(_) -> nil
  end
end

# The reader never waits for the node: a mail goes to the node at once or is dropped and counted (at most once). Only
# mails go through the node; the frames of the heartbeat are for the link alone.
def deliver(config: Types.Config, peer: Types.Peer, mailbox: String, body: Bytes) -> Void
  case Actor.cast(config.node, Types.Msg.Deliver(peer.name, mailbox, body), 0)
    ok(_) -> nil
    error(_) -> _ = config.counts.add(Types.DROPPED, 1)
  end
end

# The client dialed a node, maybe by its name (`expected`): with a name, the transcript uses it and never the name in
# the challenge, so a node that answers under another name fails the proof.
def client_handshake(
  config: Types.Config,
  socket: TCP.Socket,
  endpoint: Types.Endpoint,
  deadline: Int,
  nonce: Bytes,
) -> Result[Types.Peer]
  hello = try Wire.encode(Types.Message.Hello(config.name, nonce))
  try send(socket, Wire.preamble() + hello, deadline)
  try Wire.check_preamble(try read_exact(socket, PREAMBLE_BYTES, deadline, none))
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline, none)
    Types.Message.Challenge(server, server_nonce, server_proof) ->
      name = endpoint.node
      if name.empty?
        name = server
      end

      session = try Handshake.session(config.name, name, nonce, server_nonce)
      proof = try Handshake.answer(config.cookie, session, server_proof)
      try send(socket, try Wire.encode(proof), deadline)
      try expect_welcome(socket, deadline)
      ok(
        Types.Peer(
          name: name,
          dialer: config.name,
          endpoint: Endpoint.key(endpoint),
          link: Task.current(),
          socket: socket,
        ),
      )
    _ -> out_of_order()
  end
end

def server_handshake(config: Types.Config, socket: TCP.Socket, deadline: Int) -> Result[Types.Peer]
  try send(socket, Wire.preamble(), deadline)
  try Wire.check_preamble(try read_exact(socket, PREAMBLE_BYTES, deadline, none))
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline, none)
    Types.Message.Hello(client, client_nonce) ->
      try not_itself(config, client, client_nonce)
      session = try Handshake.session(client, config.name, client_nonce, Handshake.fresh_nonce())
      try send(socket, try Wire.encode(Handshake.challenge(config.cookie, session)), deadline)
      case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline, none)
        Types.Message.Proof(proof) ->
          welcome = try Handshake.accept(config.cookie, session, proof)
          try send(socket, try Wire.encode(welcome), deadline)
          ok(Types.Peer(name: client, dialer: client, endpoint: "", link: Task.current(), socket: socket))
        _ -> out_of_order()
      end

    _ -> out_of_order()
  end
end

# A hello of the name of this node with the nonce of a dial of this node is the node dialing itself: the dial is
# told, and
# nothing is counted as refused. A hello of that name with another nonce is another node that took the name.
def not_itself(config: Types.Config, client: String, client_nonce: Bytes) -> Result[Void]
  mark = "#{DIAL}#{OpenSSL.Digest.hexencode(client_nonce)}"
  return ok() if client != config.name or not config.counts.has_key?(mark)

  config.counts.put(mark, ITSELF)
  closed("the node dialed itself")
end

def expect_welcome(socket: TCP.Socket, deadline: Int) -> Result[Void]
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline, none)
    Types.Message.Welcome -> ok()
    _ -> out_of_order()
  end
end

def out_of_order[T]() -> Result[T]
  error("cluster: a frame that is not the next one of the handshake", kind: Types.PROTOCOL)
end

def closed[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.CLOSED)

# The time left until the deadline, in milliseconds.
def left(deadline: Int) -> Result[Int]
  remaining = deadline - Time.monotonic_ms()
  return closed("the handshake took too long") if remaining <= 0

  ok(remaining)
end

def send(socket: TCP.Socket, bytes: Bytes, deadline: Int) -> Result[Void]
  case TCP.send_bytes(socket, bytes, try left(deadline))
    ok(_) -> ok()
    error(_) -> closed("the connection ended")
  end
end

# `count` bytes, from as many reads as it takes. A deadline of 0 waits with no limit (a link that is up), and `seen`,
# when there is one, gets the time of each chunk.
def read_exact(socket: TCP.Socket, count: Int, deadline: Int, seen: Optional[ATS[String, Int]]) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    got = try read_some(socket, count - have, deadline)
    return closed("the connection ended") if got.empty?

    touch(seen)

    parts = parts.push(got)
    have += got.size
  end

  ok(Bytes.concat(parts))
end

def touch(seen: Optional[ATS[String, Int]]) -> Void
  case seen
    some(table) -> table.put(SEEN, Time.monotonic_ms())
    none -> nil
  end
end

def read_some(socket: TCP.Socket, count: Int, deadline: Int) -> Result[Bytes]
  return wrap(TCP.recv_bytes(socket, count)) if deadline == 0

  wrap(TCP.recv_bytes(socket, count, try left(deadline)))
end

def wrap(read: Result[Bytes]) -> Result[Bytes]
  case read
    ok(bytes) -> ok(bytes)
    error(_) -> closed("the connection ended")
  end
end

# One frame: its length is checked against `limit` before the body is read.
def read_message(
  socket: TCP.Socket,
  limit: Int,
  deadline: Int,
  seen: Optional[ATS[String, Int]],
) -> Result[Types.Message]
  header = try read_exact(socket, HEADER_BYTES, deadline, seen)
  length = try Wire.frame_length(header, limit)
  Wire.decode(try read_exact(socket, length, deadline, seen))
end

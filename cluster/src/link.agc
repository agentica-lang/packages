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
PREAMBLE_BYTES = 6
HEADER_BYTES = 4

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
  case client_handshake(config, socket, args.endpoint, deadline)
    error(e) ->
      TCP.close(socket)
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

# After the welcome a link is read: a bye ends it, a mail goes to the node, and any other frame is ignored.
def keep_reading(config: Types.Config, socket: TCP.Socket, peer: Types.Peer) -> Void
  reading = true
  while reading
    case read_message(socket, config.max_frame_bytes, 0)
      ok(Types.Message.Bye(_)) -> reading = false
      ok(Types.Message.Mail(mailbox, body)) -> deliver(config, peer, mailbox, body)
      ok(_) -> nil
      error(_) -> reading = false
    end
  end

  TCP.close(socket)
  _ = Actor.cast(config.node, Types.Msg.Closed(peer.name, peer.link.id))
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
) -> Result[Types.Peer]
  nonce = Handshake.fresh_nonce()
  hello = try Wire.encode(Types.Message.Hello(config.name, nonce))
  try send(socket, Wire.preamble() + hello, deadline)
  try Wire.check_preamble(try read_exact(socket, PREAMBLE_BYTES, deadline))
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline)
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
  try Wire.check_preamble(try read_exact(socket, PREAMBLE_BYTES, deadline))
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline)
    Types.Message.Hello(client, client_nonce) ->
      session = try Handshake.session(client, config.name, client_nonce, Handshake.fresh_nonce())
      try send(socket, try Wire.encode(Handshake.challenge(config.cookie, session)), deadline)
      case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline)
        Types.Message.Proof(proof) ->
          welcome = try Handshake.accept(config.cookie, session, proof)
          try send(socket, try Wire.encode(welcome), deadline)
          ok(Types.Peer(name: client, dialer: client, endpoint: "", link: Task.current(), socket: socket))
        _ -> out_of_order()
      end

    _ -> out_of_order()
  end
end

def expect_welcome(socket: TCP.Socket, deadline: Int) -> Result[Void]
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline)
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

# `count` bytes, from as many reads as it takes. A deadline of 0 waits with no limit (a link that is up).
def read_exact(socket: TCP.Socket, count: Int, deadline: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    got = try read_some(socket, count - have, deadline)
    return closed("the connection ended") if got.empty?

    parts = parts.push(got)
    have += got.size
  end

  ok(Bytes.concat(parts))
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
def read_message(socket: TCP.Socket, limit: Int, deadline: Int) -> Result[Types.Message]
  header = try read_exact(socket, HEADER_BYTES, deadline)
  length = try Wire.frame_length(header, limit)
  Wire.decode(try read_exact(socket, length, deadline))
end

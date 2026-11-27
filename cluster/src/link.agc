## One connection of a node, in the task that owns its socket: the handshake (as the side that dials or the side that
## accepts), then the reading of frames until the connection ends. The node hears of it through its address.

import Actor from "std/actor"
import Handshake from "handshake"
import Types from "types"
import Wire from "wire"

## What a task that dials needs: where to connect, and the channel that gets the name of the peer, or why not.
struct Dial
  config: Types.Config
  host: String
  port: Int
  reply: Channel[Result[String]]
end

## What a task that accepts gets: the socket (which it owns) and the configuration of the node.
struct Served
  config: Types.Config
  socket: TCP.Socket
end

## Dials, shakes hands as the client and, once the node keeps the link, reads it until it ends.
def dial(args: Dial) -> Void
  config = args.config
  deadline = Time.monotonic_ms() + config.connect_ms
  case TCP.connect(args.host, args.port, config.connect_ms)
    error(e) -> fail(args, error("cluster: #{args.host}:#{args.port} is not reachable: #{e.message}", kind: Types.UNREACHABLE))
    ok(socket) -> run_client(args, socket, deadline)
  end
end

## Shakes hands as the server and, once the node keeps the link, reads it until it ends.
def serve(served: Served) -> Void
  config = served.config
  socket = served.socket
  case server_handshake(config, socket, Time.monotonic_ms() + config.connect_ms)
    error(e) -> refuse(config, socket, e)
    ok(peer) -> run_link(config, socket, peer)
  end
end

private

CLOSE_REASON = "refused"

def fail(args: Dial, result: Result[String]) -> Void
  _ = args.reply.send(result, 0)
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
  case client_handshake(config, socket, deadline)
    error(e) ->
      TCP.close(socket)
      fail(args, error(e.message, kind: e.kind))

    ok(peer) ->
      kept = register(config, peer)
      _ = args.reply.send(ok(peer.name), 0)
      if kept
        keep_reading(config, socket, peer)
      end
  end
end

def run_link(config: Types.Config, socket: TCP.Socket, peer: Types.Peer) -> Void
  if register(config, peer)
    keep_reading(config, socket, peer)
  end
end

# A refused handshake says why to a peer that is still listening, and then the socket closes. A count is kept for a
# peer that failed the cookie or the names, not for bytes that never were a handshake.
def refuse(config: Types.Config, socket: TCP.Socket, e: Error) -> Void
  if e.is_a?(Types.REFUSED)
    _ = Actor.cast(config.node, Types.Msg.Refused)
  end

  say_bye(socket, CLOSE_REASON)
  TCP.close(socket)
end

def say_bye(socket: TCP.Socket, reason: String) -> Void
  case Wire.encode(Types.Message.Bye(reason))
    ok(frame) -> _ = TCP.send_bytes(socket, frame, BYE_MS)
    error(_) -> nil
  end
end

BYE_MS = 200

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

REGISTER_MS = 5000

def keep_reading(config: Types.Config, socket: TCP.Socket, peer: Types.Peer) -> Void
  reading = true
  while reading
    case read_message(socket, config.max_frame_bytes, 0)
      ok(Types.Message.Bye(_)) -> reading = false
      ok(_) -> nil
      error(_) -> reading = false
    end
  end

  TCP.close(socket)
  _ = Actor.cast(config.node, Types.Msg.Closed(peer.name, Task.current().id))
end

def client_handshake(config: Types.Config, socket: TCP.Socket, deadline: Int) -> Result[Types.Peer]
  nonce = Handshake.fresh_nonce()
  hello = try Wire.encode(Handshake.hello(config.name, nonce))
  try send(socket, Wire.preamble() + hello, deadline)
  try Wire.check_preamble(try read_exact(socket, PREAMBLE_BYTES, deadline))
  case try read_message(socket, Types.PRE_AUTH_MAX_FRAME_BYTES, deadline)
    Types.Message.Challenge(server, server_nonce, server_proof) ->
      session = try Handshake.session(config.name, server, nonce, server_nonce)
      answer = Handshake.answer(Types.Cookie.bytes(config), session, server_proof)
      return refused_at(socket, answer)
    Types.Message.Bye(reason) -> error("cluster: the node said #{reason}", kind: Types.REFUSED)
    _ -> error("cluster: the first answer is not a challenge", kind: Types.PROTOCOL)
  end
end

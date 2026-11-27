## Agentica nodes that connect with a shared cookie. A node listens, dials the peers of its list, proves the cookie to
## each (see docs/protocol.md), and knows which peers are connected.
##
## Start a node from `main` or from a supervisor: its actor and its tasks end with the task that started them.

import Actor from "std/actor"
import Check from "src/check"
import Listener from "src/listener"
import Members from "src/members"
import Names from "src/names"
import Types from "src/types"
import Wire from "src/wire"

export Types.PROTOCOL
export Types.REFUSED
export Types.ARGUMENT
export Types.UNREACHABLE
export Types.CLOSED
export Types.NOT_CONNECTED
export Types.TOO_LARGE
export Types.MAX_FRAME_BYTES
export Types.Options
export Types.Node
export Types.Delivery

## Starts a node: it listens on `host` and `port` (0 picks a free port) and dials each of `peers` in the background.
## A bad option is a `cluster.argument` error. Plain TCP is only for this machine unless `insecure_plaintext` is set.
def start(options: Types.Options) -> Result[Types.Node]
  endpoints = try Check.check(options)
  pending: ATS[String, Int] = ATS.new()
  actor = Actor.start(Members.behaviour(options, pending))
  ready: Channel[Result[Int]] = Channel.new(1)
  config = Members.config(options, actor.address, pending)
  accept = Listener.Accept(config: config, host: options.host, port: options.port, ready: ready)
  acceptor = Task.spawn(&Listener.run, accept)
  case ready.recv(options.connect_ms)
    ok(listened) -> up(options, actor, acceptor, listened, endpoints)
    error(_) -> abort(actor, acceptor, error("cluster: the node did not start", kind: Types.ARGUMENT))
  end
end

## The port that the node listens on.
def port(node: Types.Node) -> Int = node.port

## The names of the peers that are connected now, in order.
def nodes(node: Types.Node) -> List[String]
  names: Result[List[String]] = Actor.call(node.actor.address, ASK_MS, ->(reply) { Types.Msg.Names(reply) })
  # A node that is stopped has no peers.
  names.unwrap_or([])
end

## How many handshakes the node refused so far: a peer that did not know the cookie, or that used a name that it may
## not.
def refused(node: Types.Node) -> Int
  count: Result[Int] = Actor.call(node.actor.address, ASK_MS, ->(reply) { Types.Msg.Refusals(reply) })
  # A node that is stopped refused nothing more.
  count.unwrap_or(0)
end

## Connects to `host:port` (or `name@host:port`, which also checks the name of the node there) and waits for the
## handshake: it gives the name of the peer, or an error of the kind `cluster.unreachable`, `cluster.refused`,
## `cluster.closed` or `cluster.protocol`. A node already connected to that peer keeps its link.
def connect(node: Types.Node, address: String) -> Result[String]
  endpoint = try Check.endpoint(address, node.insecure_plaintext)
  reply: Channel[Result[String]] = Channel.new(1)
  case Actor.cast(node.actor.address, Types.Msg.Dial(endpoint, reply))
    error(_) -> error("cluster: the node is stopped", kind: Types.CLOSED)
    ok(_) -> answer_of(reply, node.connect_ms)
  end
end

## Registers the mailbox `name` of this node: what a peer sends to it comes to `address`, as a `Delivery` that `wrap`
## turns into the message type `M` of that address (`->(delivery) { delivery }` for a channel of deliveries). A mailbox
## that cannot take a message at once, and a message for a mailbox that does not exist, are dropped and counted
## (`dropped`). Registering a name again replaces the mailbox.
def register[M](node: Types.Node, name: String, address: Address[M], wrap: Fn[Types.Delivery, M]) -> Result[Void]
  if not Names.mailbox_name?(name)
    return error("cluster: a mailbox name has 1 to #{Types.MAX_MAILBOX_BYTES} bytes", kind: Types.ARGUMENT)
  end

  take = ->(delivery: Types.Delivery) { address.send(wrap.call(delivery), 0).ok? }
  registered: Result[Bool] = Actor.call(
    node.actor.address,
    ASK_MS,
    ->(reply) { Types.Msg.Register(name, take, reply) },
  )

  _ = try registered
  ok()
end

## Sends `body` to the mailbox `mailbox` of the connected peer `peer`. The body is the bytes of `Term.encode(value)`:
## the receiver decodes them into its own type with `Term.decode`, so what does not fit is an error there, not a crash.
## The call returns once the bytes are in the socket, which says nothing about the mailbox: delivery is at most once,
## with no reply and no retry. It fails with `cluster.not_connected` (no link to that peer), `cluster.too_large` (the
## frame is over `max_frame_bytes`) or `cluster.closed` (the link broke, or the write took more than `timeout_ms`).
def send(node: Types.Node, peer: String, mailbox: String, body: Bytes, timeout_ms: Int = ASK_MS) -> Result[Void]
  frame = try Wire.encode(Types.Message.Mail(mailbox, body), node.max_frame_bytes)
  asked: Result[Optional[TCP.Socket]] = Actor.call(
    node.actor.address,
    ASK_MS,
    ->(reply) { Types.Msg.Route(peer, reply) },
  )

  case try asked
    some(socket) -> write(socket, frame, timeout_ms)
    none -> error("cluster: that peer is not connected", kind: Types.NOT_CONNECTED)
  end
end

## How many messages the node dropped: for a mailbox that does not exist, or one that could not take them.
def dropped(node: Types.Node) -> Int
  count: Result[Int] = Actor.call(node.actor.address, ASK_MS, ->(reply) { Types.Msg.Dropped(reply) })
  # A node that is stopped drops nothing more.
  count.unwrap_or(0)
end

## Stops the node: the listener, the links, the connections that are being dialed and the actor. It waits at most
## `timeout_ms` for the actor to end, and gives the error of `std/actor` if it does not.
def stop(node: Types.Node, timeout_ms: Int) -> Result[Void]
  Task.cancel(node.acceptor)
  Actor.stop(node.actor, timeout_ms)
end

private

ASK_MS = 5000

def write(socket: TCP.Socket, frame: Bytes, timeout_ms: Int) -> Result[Void]
  case TCP.send_bytes(socket, frame, timeout_ms)
    ok(_) -> ok()
    error(_) -> error("cluster: the link to that peer broke or is too slow", kind: Types.CLOSED)
  end
end

# The dial always answers (an error too) within `connect_ms`; the wait is a little longer, for the actor to pass it on.
def answer_of(reply: Channel[Result[String]], connect_ms: Int) -> Result[String]
  case reply.recv(connect_ms + ASK_MS)
    ok(answer) -> answer
    error(_) -> error("cluster: no answer in time", kind: Types.UNREACHABLE)
  end
end

def up(
  options: Types.Options,
  actor: Actor.Ref[Types.State, Types.Msg],
  acceptor: Task[Void],
  listened: Result[Int],
  endpoints: List[Types.Endpoint],
) -> Result[Types.Node]
  case listened
    error(e) -> abort(actor, acceptor, error(e.message, kind: e.kind))
    ok(port) ->
      for endpoint in endpoints
        quiet: Channel[Result[String]] = Channel.new(1)
        _ = Actor.cast(actor.address, Types.Msg.Dial(endpoint, quiet))
      end

      ok(
        Types.Node(
          name: options.name,
          port: port,
          connect_ms: options.connect_ms,
          max_frame_bytes: options.max_frame_bytes,
          insecure_plaintext: options.insecure_plaintext,
          actor: actor,
          acceptor: acceptor,
        ),
      )
  end
end

def abort[T](actor: Actor.Ref[Types.State, Types.Msg], acceptor: Task[Void], failure: Result[T]) -> Result[T]
  Task.cancel(acceptor)
  _ = Actor.stop(actor, ASK_MS)
  failure
end

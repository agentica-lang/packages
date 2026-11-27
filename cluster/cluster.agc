## Agentica nodes that connect with a shared cookie. A node listens, dials the peers of its list, proves the cookie to
## each (see docs/protocol.md), and knows which peers are connected.
##
## Start a node from `main` or from a supervisor: its actor and its tasks end with the task that started them.

import Actor from "std/actor"
import Check from "src/check"
import Listener from "src/listener"
import Members from "src/members"
import Types from "src/types"

export Types.PROTOCOL
export Types.REFUSED
export Types.ARGUMENT
export Types.UNREACHABLE
export Types.CLOSED
export Types.TOO_LARGE
export Types.Options
export Types.Node

## Starts a node: it listens on `host` and `port` (0 picks a free port) and dials each of `peers` in the background.
## A bad option is a `cluster.argument` error. Plain TCP is only for this machine unless `insecure_plaintext` is set.
def start(options: Types.Options) -> Result[Types.Node]
  endpoints = try Check.check(options)
  actor = Actor.start(Members.behaviour(options))
  ready: Channel[Result[Int]] = Channel.new(1)
  config = Members.config(options, actor.address)
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
  names.unwrap_or([])
end

## How many handshakes the node refused so far: a peer that did not know the cookie, or that used a name that it may
## not.
def refused(node: Types.Node) -> Int
  count: Result[Int] = Actor.call(node.actor.address, ASK_MS, ->(reply) { Types.Msg.Refusals(reply) })
  count.unwrap_or(0)
end

## Connects to `host:port` (or `name@host:port`, which also checks the name of the node there) and waits for the
## handshake: it gives the name of the peer, or an error of the kind `cluster.unreachable`, `cluster.refused`,
## `cluster.closed` or `cluster.protocol`. A node already connected to that peer keeps its link.
def connect(node: Types.Node, address: String) -> Result[String]
  endpoint = try Check.endpoint(address, node.insecure_plaintext)
  reply: Channel[Result[String]] = Channel.new(1)
  try Actor.cast(node.actor.address, Types.Msg.Dial(endpoint, reply))
  answer = try reply.recv(node.connect_ms + ASK_MS)
  answer
end

## Stops the node: the listener, the links and the actor.
def stop(node: Types.Node, timeout_ms: Int) -> Result[Void]
  Task.cancel(node.acceptor)
  Actor.stop(node.actor, timeout_ms)
end

private

ASK_MS = 5000

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

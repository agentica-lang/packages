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
export Types.Event
export Types.Member

## Starts a node: it listens on `host` and `port` (0 picks a free port) and dials each of `peers` in the background.
## A bad option is a `cluster.argument` error. Plain TCP is only for this machine unless `insecure_plaintext` is set.
def start(options: Types.Options) -> Result[Types.Node]
  endpoints = try Check.check(options)
  discovery = try Check.discovery(options)
  counts: ATS[String, Int] = ATS.new()
  actor = Actor.start(Members.behaviour(options, counts))
  ready: Channel[Result[Int]] = Channel.new(1)
  config = Members.config(options, actor.address, counts)
  accept = Listener.Accept(config: config, host: options.host, port: options.port, ready: ready)
  acceptor = Task.spawn(&Listener.run, accept)
  case ready.recv(options.connect_ms)
    ok(listened) -> up(options, actor, acceptor, counts, listened, Plan(endpoints: endpoints, discovery: discovery))
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
## turns into the message type `M` of that address (`->(delivery) { delivery }` for a channel of deliveries). The
## capacity of the channel is the bound of the mailbox: a message that does not fit at once, and a message for a
## mailbox that does not exist, are dropped and counted (`dropped`). An unbounded channel never drops, and one that
## nobody reads fills the memory. `wrap` runs in the actor of the node, so it must be pure and cheap. Registering a
## name again replaces the mailbox.
def register[M](node: Types.Node, name: String, address: Address[M], wrap: Fn[Types.Delivery, M]) -> Result[Void]
  if not Names.mailbox_name?(name)
    return error("cluster: a mailbox name has 1 to #{Types.MAX_MAILBOX_BYTES} bytes", kind: Types.ARGUMENT)
  end

  take = ->(delivery: Types.Delivery) { address.send(wrap.call(delivery), 0).ok? }
  _ = try ask(node, ->(reply: Channel[Bool]) { Types.Msg.Register(name, take, reply) })
  ok()
end

## Sends `body` to the mailbox `mailbox` of the connected peer `peer`. The body is the bytes of `Term.encode(value)`:
## the receiver decodes them into its own type with `Term.decode`, so what does not fit is an error there, not a crash.
## The call returns once the bytes are in the socket, which says nothing about the mailbox: delivery is at most once,
## with no reply and no retry. It fails with `cluster.argument` (`timeout_ms` is less than 1), `cluster.not_connected`
## (no link to that peer), `cluster.too_large` (the frame is over `max_frame_bytes`) or `cluster.closed` (the node
## stopped, the link broke, or the write took more than `timeout_ms`: that closes the link, and the peer is down until
## it is connected again). A frame over the limit of the receiver also ends the whole link there.
def send(node: Types.Node, peer: String, mailbox: String, body: Bytes, timeout_ms: Int = ASK_MS) -> Result[Void]
  return error("cluster: timeout_ms is at least 1", kind: Types.ARGUMENT) if timeout_ms < 1

  frame = try Wire.encode(Types.Message.Mail(mailbox, body), node.max_frame_bytes)
  asked = try ask(node, ->(reply: Channel[Optional[TCP.Socket]]) { Types.Msg.Route(peer, reply) })
  case asked
    some(socket) -> write(socket, frame, timeout_ms)
    none -> error("cluster: that peer is not connected", kind: Types.NOT_CONNECTED)
  end
end

## Puts the registered mailbox `mailbox` of this node in the group `group` (a name of 1 to 255 bytes, as a mailbox
## has), and tells the connected peers; the ones that connect later hear it when they connect. Joining twice is one
## membership. It fails with `cluster.argument` (a name that is not valid, or a mailbox that is not registered here) or
## `cluster.too_large` (the groups of the node do not fit in a frame). The membership stays until `group_leave`, even
## if the mailbox is registered again; a message for a mailbox that is gone is dropped and counted.
def group_join(node: Types.Node, group: String, mailbox: String) -> Result[Void]
  try named_group(group, mailbox)
  joined = try ask(node, ->(reply: Channel[Result[Void]]) { Types.Msg.Join(group, mailbox, reply) })
  joined
end

## Takes the mailbox `mailbox` of this node out of the group `group`, and tells the peers. A mailbox that is not in the
## group is not an error.
def group_leave(node: Types.Node, group: String, mailbox: String) -> Result[Void]
  try named_group(group, mailbox)
  _ = try ask(node, ->(reply: Channel[Bool]) { Types.Msg.Leave(group, mailbox, reply) })
  ok()
end

## The members of the group `group`, this node's and the peers' that are connected now, ordered by node and mailbox. A
## peer that is down is not there: its memberships end with its link, and come back when it connects again.
def group_members(node: Types.Node, group: String) -> Result[List[Types.Member]]
  ask(node, ->(reply: Channel[List[Types.Member]]) { Types.Msg.Members(group, reply) })
end

## Sends `body` (the bytes of `Term.encode(value)`, as for `send`) to the mailbox of each member of the group `group`.
## This node's own members get it through the queue of the node. The members of a peer are written to its link one
## after the other, in the order of `group_members`, and the peers are written at the same time (at most 64 at once).
## `timeout_ms` is for all the frames of one peer: a write that fails or times out closes the link, and the members
## not yet written are not counted, while the other peers are not held. When the time passes between two frames, the
## link stays open and the rest are not counted. With more than 64 peers the call can take `ceil(peers / 64)` times
## `timeout_ms`. It gives how many members it reached, which says that the
## bytes are in the socket of the link (or in the queue of this node), not that the mailbox took them: the mailbox may
## be full, not registered there, or the peer may die after the write. A member of this node is not counted if the
## queue of the node is full. A peer that is not connected is not counted, and the call goes on, so it is `0` for a
## group with no members. The memberships are the ones that this node has now, so a peer that joined a moment ago may
## not get it. Delivery is at most once, as for `send`. It fails with `cluster.argument` (a name that is not valid, or
## `timeout_ms` is less than 1), `cluster.too_large` (a frame is over `max_frame_bytes`: then nothing is sent) or
## `cluster.closed` (the node is stopped).
def group_send(node: Types.Node, group: String, body: Bytes, timeout_ms: Int = ASK_MS) -> Result[Int]
  return error("cluster: timeout_ms is at least 1", kind: Types.ARGUMENT) if timeout_ms < 1

  try named_group(group, group)
  members = try group_members(node, group)
  try fits(node, members, body)
  jobs = peer_jobs(node, members, body, timeout_ms)
  reached = (
    members.select { |member| member.node == node.name }
      .select { |member| deliver_here(node, member, body) }
      .size
  )

  written: List[Result[Int]] = Task.map(
    jobs,
    [jobs.size, 1].max.unwrap!.clamp(1, MAX_PEERS_AT_ONCE),
    timeout_ms + ASK_MS,
    &write_to_peer,
  )

  ok(reached + written.map { |count| count.unwrap_or(0) }.sum)
end

## Tells `address` when a peer comes or goes: `Event.NodeUp(name)` when the first link to a peer is kept, and
## `Event.NodeDown(name)` when its link ends (it said bye, the socket closed, or it was silent for 3 heartbeats).
## `wrap` makes the message of that address from the event, and it runs in the actor of the node, so it must be pure
## and cheap. As with a mailbox, a watcher that cannot take an event at once misses it, so the capacity of its channel
## is its bound. A link that replaces another one of the same peer is not an event. Events start from the call: a peer
## that is already connected is not told.
def watch[M](node: Types.Node, address: Address[M], wrap: Fn[Types.Event, M]) -> Result[Void]
  tell = ->(event: Types.Event) { address.send(wrap.call(event), 0).ok? }
  _ = try ask(node, ->(reply: Channel[Bool]) { Types.Msg.Watch(tell, reply) })
  ok()
end

## How many messages the node dropped: for a mailbox that does not exist, one that could not take them, or because the
## node was too busy to look at them.
def dropped(node: Types.Node) -> Int = node.counts.get(Types.DROPPED).unwrap_or(0)

## Stops the node: the listener, the links, the connections that are being dialed and the actor. It waits at most
## `timeout_ms` for the actor to end, and gives the error of `std/actor` if it does not.
def stop(node: Types.Node, timeout_ms: Int) -> Result[Void]
  Task.cancel(node.acceptor)
  Actor.stop(node.actor, timeout_ms)
end

private

ASK_MS = 5000
MAX_PEERS_AT_ONCE = 64

# What a node dials once it listens: the peers of its list, and the name to look up.
struct Plan
  endpoints: List[Types.Endpoint]
  discovery: Optional[Types.Endpoint]
end

# What the task that writes to one peer needs: its mailboxes, in order. The node is only its address, since a task
# takes data and not the node.
struct Job
  actor: Address[Types.Msg]
  peer: String
  mailboxes: List[String]
  body: Bytes
  max_frame_bytes: Int
  timeout_ms: Int
end

def ask[R](node: Types.Node, make: Fn[Channel[R], Types.Msg]) -> Result[R]
  case Actor.call(node.actor.address, ASK_MS, make)
    ok(answer) -> ok(answer)
    error(_) -> error("cluster: the node is stopped or too busy", kind: Types.CLOSED)
  end
end

def named_group(group: String, mailbox: String) -> Result[Void]
  return ok() if Names.mailbox_name?(group) and Names.mailbox_name?(mailbox)

  error("cluster: a group and a mailbox name have 1 to #{Types.MAX_MAILBOX_BYTES} bytes", kind: Types.ARGUMENT)
end

# The biggest frame of the call is the one for the longest mailbox name: if that one fits, all do, and a body that is
# too big sends to nobody. No frame is kept: each one is made when its peer is written.
def fits(node: Types.Node, members: List[Types.Member], body: Bytes) -> Result[Void]
  return ok() if members.empty?

  longest = members.map { |member| member.mailbox }.max_by { |name| name.bytes.size }.unwrap!
  _ = try Wire.encode(Types.Message.Mail(longest, body), node.max_frame_bytes)
  ok()
end

# The members of the peers, one job for each peer, with its mailboxes in the order of the members.
def peer_jobs(node: Types.Node, members: List[Types.Member], body: Bytes, timeout_ms: Int) -> List[Job]
  remote = members.select { |member| member.node != node.name }
  remote.map { |member| member.node }.uniq.map do |peer|
    mailboxes = remote.select { |member| member.node == peer }.map { |member| member.mailbox }
    Job(actor: node.actor.address, peer: peer, mailboxes: mailboxes, body: body, max_frame_bytes: node.max_frame_bytes, timeout_ms: timeout_ms)
  end
end

# One Route, then the frames of the peer one after the other until the time is up or one fails. It gives how many were
# written.
def write_to_peer(job: Job) -> Result[Int]
  deadline = Time.monotonic_ms() + job.timeout_ms
  asked: Result[Optional[TCP.Socket]] = Actor.call(
    job.actor,
    [job.timeout_ms, ASK_MS].min.unwrap!,
    ->(reply) { Types.Msg.Route(job.peer, reply) },
  )

  case asked
    ok(some(socket)) -> write_all(job, socket, deadline)
    _ -> ok(0)
  end
end

def write_all(job: Job, socket: TCP.Socket, deadline: Int) -> Result[Int]
  written = 0
  for mailbox in job.mailboxes
    left = deadline - Time.monotonic_ms()
    return ok(written) if left < 1

    frame = try Wire.encode(Types.Message.Mail(mailbox, job.body), job.max_frame_bytes)
    return ok(written) if not write(socket, frame, left).ok?

    written += 1
  end

  ok(written)
end

# A member of this node goes into the queue of the node, as a message from a peer does, and it counts as reached when
# the node took it.
def deliver_here(node: Types.Node, member: Types.Member, body: Bytes) -> Bool
  Actor.cast(node.actor.address, Types.Msg.Deliver(node.name, member.mailbox, body), 0).ok?
end

# A write that fails may have sent half a frame, so the link is closed: the reader of the link ends it.
def write(socket: TCP.Socket, frame: Bytes, timeout_ms: Int) -> Result[Void]
  case TCP.send_bytes(socket, frame, timeout_ms)
    ok(_) -> ok()
    error(_) ->
      TCP.close(socket)
      error("cluster: the link to that peer broke or is too slow", kind: Types.CLOSED)
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
  counts: ATS[String, Int],
  listened: Result[Int],
  plan: Plan,
) -> Result[Types.Node]
  case listened
    error(e) -> abort(actor, acceptor, error(e.message, kind: e.kind))
    ok(port) ->
      _ = Actor.cast(actor.address, Types.Msg.Keep(plan.endpoints))
      case plan.discovery
        some(endpoint) -> _ = Actor.cast(actor.address, Types.Msg.Discover(endpoint))
        none -> nil
      end

      ok(
        Types.Node(
          name: options.name,
          port: port,
          connect_ms: options.connect_ms,
          max_frame_bytes: options.max_frame_bytes,
          insecure_plaintext: options.insecure_plaintext,
          counts: counts,
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

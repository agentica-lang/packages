## The actor of a node: it knows the peers by name, decides which of two links to the same peer stays, and starts the
## tasks that dial. The listener is a task of its own (src/listener.agc), and each connection is a task (src/link.agc).

import Actor from "std/actor"
import Endpoint from "endpoint"
import Discover from "discover"
import Link from "link"
import Types from "types"
import Wire from "wire"

## The behaviour of the actor of a node with these options.
def behaviour(options: Types.Options, counts: ATS[String, Int]) -> Actor.Behaviour[Types.State, Types.Msg]
  Actor.Behaviour(init: -> { start_state(options, counts) }, handle: &handle, terminate: some(&terminate))
end

## What the tasks of a node share, once the address of its actor is known. `counts` is the table that all the tasks of
## the node add to.
def config(options: Types.Options, node: Address[Types.Msg], counts: ATS[String, Int]) -> Types.Config
  Types.Config(
    name: options.name,
    cookie: options.cookie.bytes,
    connect_ms: options.connect_ms,
    heartbeat_ms: options.heartbeat_ms,
    discover_ms: options.discover_ms,
    reconnect_ms: options.reconnect_ms,
    reconnect_max_ms: options.reconnect_max_ms,
    max_pending: options.max_pending,
    counts: counts,
    max_frame_bytes: options.max_frame_bytes,
    node: node,
  )
end

## Whether a second link to a peer replaces the one that the node has. Two nodes that connect to each other at the same
## moment make two links, which the two nodes see in either order, and both keep the one that the smaller name dialed,
## so they agree with no talk. Two links dialed by the same side are not like that: the old one stays, on both nodes.
def replaces?(new_dialer: String, old_dialer: String) -> Bool
  new_dialer != old_dialer and new_dialer.compare(old_dialer) < 0
end

private

GONE_MS = 1000
SILENT_HEARTBEATS = 3
OWN_PERIODS = 10

def start_state(options: Types.Options, counts: ATS[String, Int]) -> Types.State
  inbox: Channel[Types.Msg] = Actor.inbox
  Types.State(
    config: config(options, inbox.address, counts),
    peers: {},
    dialing: {},
    mailboxes: {},
    watchers: [],
    kept: {},
    found: {},
    finders: [],
    names: {},
    own: {},
    groups: [],
    version: 0,
    remote: {},
    delays: {},
    timers: {},
    refused: 0,
  )
end

def handle(state: Types.State, message: Types.Msg) -> Actor.Step[Types.State]
  case message
    Types.Msg.Linked(peer, reply) -> Actor.continue(link(state, peer, reply))
    Types.Msg.Closed(name, id) -> Actor.continue(unlink(state, name, id))
    Types.Msg.Dial(endpoint, reply) -> Actor.continue(dial(state, endpoint, reply))
    Types.Msg.Dialed(key, result) -> Actor.continue(retried(dialed(state, key, result), key, result))
    Types.Msg.Keep(endpoints) -> Actor.continue(keep_all(state, endpoints))
    Types.Msg.Redial(key) -> Actor.continue(redial(state, key))
    Types.Msg.Discover(endpoint) -> Actor.continue(discover(state, endpoint))
    Types.Msg.Found(endpoints) -> Actor.continue(found(state, endpoints))
    Types.Msg.Own(key) -> Actor.continue(owned(state, key))
    Types.Msg.Join(group, mailbox, reply) -> join(state, Types.Membership(group: group, mailbox: mailbox), reply)
    Types.Msg.Leave(group, mailbox, reply) -> leave(state, Types.Membership(group: group, mailbox: mailbox), reply)
    Types.Msg.Members(group, reply) -> answer(state, reply, members(state, group))
    Types.Msg.Groups(name, version, memberships) -> Actor.continue(heard(state, name, version, memberships))
    Types.Msg.Refused -> Actor.continue(state.with(refused: state.refused + 1))
    Types.Msg.Names(reply) -> answer(state, reply, state.peers.keys.sort)
    Types.Msg.Refusals(reply) -> answer(state, reply, state.refused)
    Types.Msg.Deliver(from, mailbox, body) ->
      Actor.continue(deliver(state, Types.Delivery(from: from, mailbox: mailbox, body: body)))
    Types.Msg.Register(name, take, reply) ->
      answer(state.with(mailboxes: state.mailboxes.put(name, take)), reply, true)
    Types.Msg.Route(name, reply) -> answer(state, reply, socket_of(state, name))
    Types.Msg.Watch(tell, reply) -> answer(state.with(watchers: state.watchers.push(tell)), reply, true)
  end
end

def answer[T](state: Types.State, reply: Channel[T], value: T) -> Actor.Step[Types.State]
  _ = Actor.reply(reply, value)
  Actor.continue(state)
end

# A message for a mailbox that does not exist, or that cannot take it at once, is dropped and counted.
def deliver(state: Types.State, delivery: Types.Delivery) -> Types.State
  case state.mailboxes.get(delivery.mailbox)
    some(take) -> counted(state, take.call(delivery))
    none -> dropped(state)
  end
end

def counted(state: Types.State, taken: Bool) -> Types.State
  return state if taken

  dropped(state)
end

def dropped(state: Types.State) -> Types.State
  _ = state.config.counts.add(Types.DROPPED, 1)
  state
end

def socket_of(state: Types.State, name: String) -> Optional[TCP.Socket]
  case state.peers.get(name)
    some(peer) -> some(peer.socket)
    none -> none
  end
end

# Every link and every dial in flight ends with the node, and the callers that wait for a dial hear that. The actor
# waits (a short while) for the tasks to be gone, so that `stop` leaves none behind.
def terminate(state: Types.State) -> Void
  count = state.peers.size + state.dialing.size + state.timers.size + state.finders.size
  # A channel that holds one notice for each task, so that no monitor is left waiting.
  gone: Channel[Int] = Channel.new([count, 1].max.unwrap!)
  for peer in state.peers.values
    Task.cancel(peer.link)
    Task.monitor(peer.link, gone, ->(down) { down.task_id })
  end

  for dialing in state.dialing.values
    answer_waiters(dialing.waiters, error("cluster: the node stopped", kind: Types.CLOSED))
    Task.cancel(dialing.task)
    Task.monitor(dialing.task, gone, ->(down) { down.task_id })
  end

  for timer in state.timers.values
    Task.cancel(timer)
    Task.monitor(timer, gone, ->(down) { down.task_id })
  end

  for finder in state.finders
    Task.cancel(finder)
    Task.monitor(finder, gone, ->(down) { down.task_id })
  end

  deadline = Time.monotonic_ms() + GONE_MS
  for _ in 1..count
    _ = gone.recv((deadline - Time.monotonic_ms()).clamp(0, GONE_MS))
  end
end

def link(state: Types.State, peer: Types.Peer, reply: Channel[Bool]) -> Types.State
  current = state.peers.get(peer.name)
  case current
    none -> up(keep(state, peer, reply), peer.name)
    some(old) ->
      if replaces?(peer.dialer, old.dialer)
        Task.cancel(old.link)
        keep(state, peer, reply)
      else
        _ = Actor.reply(reply, false)
        state
      end
  end
end

# A link that this node dialed answers the callers that wait for it here, not through its task: a link from a smaller
# name may replace it, and that cancels the task before it tells.
def keep(state: Types.State, peer: Types.Peer, reply: Channel[Bool]) -> Types.State
  _ = Actor.reply(reply, true)
  fresh = state.with(peers: state.peers.put(peer.name, peer), remote: state.remote.delete(peer.name))
  linked = named(told_groups(fresh, [peer]), peer.endpoint, peer.name)
  kept = settled(linked, peer.name)
  return kept if peer.endpoint.empty?

  stop_other_dial(kept, peer)
  dialed(kept, peer.endpoint, ok(peer.name))
end

# The task that dialed is the link itself; a dial of another task for that address is of no use now.
def stop_other_dial(state: Types.State, peer: Types.Peer) -> Void
  case state.dialing.get(peer.endpoint)
    some(dialing) if dialing.task.id != peer.link.id -> Task.cancel(dialing.task)
    _ -> nil
  end
end

# A link that ended is forgotten, unless another link took its place.
def unlink(state: Types.State, name: String, id: Int) -> Types.State
  case state.peers.get(name)
    some(peer) -> forget(state, peer, id)
    none -> state
  end
end

def forget(state: Types.State, peer: Types.Peer, id: Int) -> Types.State
  return state if peer.link.id != id

  gone = retry_all(state.with(peers: state.peers.delete(peer.name), remote: state.remote.delete(peer.name)), peer.name)
  down(unfound_all(gone, peer.name), peer.name)
end

# The addresses of a peer that the name gave are forgotten when its last link ends.
def unfound_all(state: Types.State, name: String) -> Types.State
  current = state
  for key in addresses_of(state, name)
    current = unfound(current, key)
  end

  current
end

def up(state: Types.State, name: String) -> Types.State = told(state, Types.Event.NodeUp(name))

def down(state: Types.State, name: String) -> Types.State = told(state, Types.Event.NodeDown(name))

# Every watcher hears it, once. A watcher that cannot take it at once misses it, and that is counted as a drop.
def told(state: Types.State, event: Types.Event) -> Types.State
  for tell in state.watchers
    if not tell.call(event)
      _ = state.config.counts.add(Types.DROPPED, 1)
    end
  end

  state
end

# An address that is linked, or a name that is linked (even if the peer dialed this node), answers at once; one that is
# being dialed adds the caller to those that wait; any other starts a task that dials.
def dial(state: Types.State, endpoint: Types.Endpoint, reply: Channel[Result[String]]) -> Types.State
  key = Endpoint.key(endpoint)
  case linked(state, key, endpoint.node)
    ok(peer) -> answered(state, reply, peer, endpoint.node)
    error(_) -> dial_new(state, key, endpoint, reply)
  end
end

def linked(state: Types.State, key: String, name: String) -> Result[Types.Peer]
  by_name = state.peers.get(name)
  case by_name
    some(peer) if not name.empty? -> ok(peer)
    _ -> state.peers.values.find { |peer| peer.endpoint == key }
  end
end

def answered(state: Types.State, reply: Channel[Result[String]], peer: Types.Peer, name: String) -> Types.State
  _ = reply.send(verdict(ok(peer.name), name), 0)
  state
end

# The answer for a caller that said the name that the address must have.
def verdict(result: Result[String], name: String) -> Result[String]
  case result
    ok(found) if not name.empty? and found != name ->
      error("cluster: that address answers under another name", kind: Types.REFUSED)
    _ -> result
  end
end

def dial_new(state: Types.State, key: String, endpoint: Types.Endpoint, reply: Channel[Result[String]]) -> Types.State
  waiter = Types.Waiter(reply: reply, name: endpoint.node)
  case state.dialing.get(key)
    some(dialing) -> state.with(dialing: state.dialing.put(key, dialing.with(waiters: dialing.waiters.push(waiter))))
    none ->
      task = Task.spawn(&Link.dial, Link.Dial(config: state.config, endpoint: endpoint))
      state.with(dialing: state.dialing.put(key, Types.Dialing(task: task, waiters: [waiter])))
  end
end

# The dial of an address is over: the callers that wait hear the result, each checked against its own name.
def dialed(state: Types.State, key: String, result: Result[String]) -> Types.State
  case state.dialing.get(key)
    some(dialing) ->
      answer_waiters(dialing.waiters, result)
      state.with(dialing: state.dialing.delete(key))
    none -> state
  end
end

def answer_waiters(waiters: List[Types.Waiter], result: Result[String]) -> Void
  for waiter in waiters
    _ = waiter.reply.send(verdict(result, waiter.name), 0)
  end
end

# The peers of the list are dialed now, and again when a dial fails or their link ends.
def keep_all(state: Types.State, endpoints: List[Types.Endpoint]) -> Types.State
  current = state
  for endpoint in endpoints
    key = Endpoint.key(endpoint)
    listed = current.with(kept: current.kept.put(key, endpoint))
    current = dial(named(listed, key, endpoint.node), endpoint, quiet_reply())
  end

  current
end

# The name that answers at an address, once it is known: it is how a link that came in is matched to the list.
def named(state: Types.State, key: String, name: String) -> Types.State
  return state if name.empty? or not (state.kept.has_key?(key) or state.found.has_key?(key))

  state.with(names: state.names.put(key, name))
end

def retried(state: Types.State, key: String, result: Result[String]) -> Types.State
  case result
    ok(name) -> named(state, key, name)
    error(_) -> unfound(retry(state, key), key)
  end
end

# The links of a peer ended: each address of the list that answers under its name is dialed again.
def retry_all(state: Types.State, name: String) -> Types.State
  current = state
  for key in addresses_of(state, name)
    current = retry(current, key)
  end

  current
end

def addresses_of(state: Types.State, name: String) -> List[String]
  state.names.keys.select { |key| state.names[key] == name }
end

# A peer that is linked needs no wait: the ones that run for its addresses are cancelled and the waits start over.
def settled(state: Types.State, name: String) -> Types.State
  current = state
  for key in addresses_of(state, name)
    case current.timers.get(key)
      some(timer) -> Task.cancel(timer)
      none -> nil
    end

    current = current.with(timers: current.timers.delete(key), delays: current.delays.delete(key))
  end

  current
end

# The wait before the next dial of a peer of the list: `reconnect_ms` at first, and twice the last one after each
# failure, up to `reconnect_max_ms`, with up to a fifth more so that peers that failed together do not come back
# together. A peer that is not of the list is not dialed again.
def retry(state: Types.State, key: String) -> Types.State
  case state.kept.get(key)
    some(_) if not state.timers.has_key?(key) -> wait(state, key)
    _ -> state
  end
end

def wait(state: Types.State, key: String) -> Types.State
  config = state.config
  last = state.delays.get(key)
  delay = [last.map { |ms| ms * 2 }.unwrap_or(config.reconnect_ms), config.reconnect_max_ms].min.unwrap!
  wait_ms = delay + Random.int(0, delay / 5)
  timer = Task.spawn(&Link.redial, Link.Redial(node: config.node, key: key, wait_ms: wait_ms))
  state.with(delays: state.delays.put(key, delay), timers: state.timers.put(key, timer))
end

# The dial is skipped when the peer is linked by now.
def redial(state: Types.State, key: String) -> Types.State
  waited = state.with(timers: state.timers.delete(key))
  case state.kept.get(key)
    some(_) if own?(state, key) -> retry(waited, key)
    some(endpoint) if not state.peers.has_key?(state.names.get(key).unwrap_or("")) ->
      dial(waited, endpoint, quiet_reply())
    _ -> waited
  end
end

# Nobody waits for the answer of a dial that the node makes by itself.
def quiet_reply() -> Channel[Result[String]] = Channel.new(1)

# The name of the cluster is looked up from now on. The lookup of a name that is not an address of this machine is
# bounded by the time that a dial has.
def discover(state: Types.State, endpoint: Types.Endpoint) -> Types.State
  config = state.config
  find = Discover.Find(
    node: config.node,
    endpoint: endpoint,
    every_ms: config.discover_ms,
    lookup_ms: config.connect_ms,
  )

  state.with(finders: state.finders.push(Task.spawn(&Discover.find, find)))
end

# An address that the name gave. It is dialed unless its peer is known and linked, or it is being dialed: a dial of an
# address that answers makes the peer known, so a linked peer costs no new connection each time. An address of the
# list is dialed as it is written there, with the name that it must answer under.
def found(state: Types.State, endpoints: List[Types.Endpoint]) -> Types.State
  current = left(state, endpoints)
  for endpoint in endpoints
    current = found_one(current, endpoint)
  end

  current
end

# An address that is not in the answer any more is not this node's any more, unless it is in the list.
def left(state: Types.State, endpoints: List[Types.Endpoint]) -> Types.State
  answered = endpoints.map { |endpoint| Endpoint.key(endpoint) }
  current = state
  for key in state.own.keys
    if not answered.include?(key) and not state.kept.has_key?(key)
      current = current.with(own: current.own.delete(key))
    end
  end

  current
end

# The node dialed itself there: the address is left alone for `OWN_PERIODS` lookups, and then it is dialed again, since
# an address that is shared (a virtual IP, a balancer) may reach this node once and another one the next time.
def owned(state: Types.State, key: String) -> Types.State
  deadline = Time.monotonic_ms() + OWN_PERIODS * state.config.discover_ms
  state.with(own: state.own.put(key, deadline))
end

# A node says all its memberships, with the number of the change: a frame that arrives late or twice is harmless, since
# the peer keeps the highest number.
def join(state: Types.State, entry: Types.Membership, reply: Channel[Result[Void]]) -> Actor.Step[Types.State]
  if not state.mailboxes.has_key?(entry.mailbox)
    return answer(state, reply, error("cluster: the mailbox is not registered", kind: Types.ARGUMENT))
  end

  return answer(state, reply, ok()) if state.groups.include?(entry)

  changed = state.with(groups: state.groups.push(entry), version: state.version + 1)
  case Wire.encode(Types.Message.Groups(changed.version, changed.groups), state.config.max_frame_bytes)
    ok(frame) -> answer(sent(changed, frame, changed.peers.values), reply, ok())
    error(e) -> answer(state, reply, error(e.message, kind: e.kind))
  end
end

def leave(state: Types.State, entry: Types.Membership, reply: Channel[Bool]) -> Actor.Step[Types.State]
  return answer(state, reply, true) if not state.groups.include?(entry)

  changed = state.with(groups: state.groups.select { |held| held != entry }, version: state.version + 1)
  answer(told_groups(changed, changed.peers.values), reply, true)
end

def told_groups(state: Types.State, peers: List[Types.Peer]) -> Types.State
  return state if state.version == 0 or peers.empty?

  case Wire.encode(Types.Message.Groups(state.version, state.groups), state.config.max_frame_bytes)
    ok(frame) -> sent(state, frame, peers)
    error(_) -> state
  end
end

def sent(state: Types.State, frame: Bytes, peers: List[Types.Peer]) -> Types.State
  wait_ms = SILENT_HEARTBEATS * state.config.heartbeat_ms
  for peer in peers
    _ = Task.spawn(&Link.announce, Link.Announce(frame: frame, socket: peer.socket, wait_ms: wait_ms))
  end

  state
end

def heard(state: Types.State, name: String, version: Int, memberships: List[Types.Membership]) -> Types.State
  return state if not state.peers.has_key?(name)
  return state if state.remote.get(name).map { |held| held.version >= version }.unwrap_or(false)

  state.with(remote: state.remote.put(name, Types.Remote(version: version, memberships: memberships)))
end

def members(state: Types.State, group: String) -> List[Types.Member]
  mine = state.groups.select { |entry| entry.group == group }.map { |entry| member(state.config.name, entry) }
  theirs = state.remote.keys.flat_map { |name| members_of(name, state.remote[name], group) }
  (mine + theirs).sort_by { |found| "#{found.node}/#{found.mailbox}" }
end

def members_of(name: String, remote: Types.Remote, group: String) -> List[Types.Member]
  remote.memberships.select { |entry| entry.group == group }.map { |entry| member(name, entry) }
end

def member(node: String, entry: Types.Membership) -> Types.Member = Types.Member(node: node, mailbox: entry.mailbox)

def own?(state: Types.State, key: String) -> Bool
  state.own.get(key).map { |deadline| deadline > Time.monotonic_ms() }.unwrap_or(false)
end

def found_one(state: Types.State, endpoint: Types.Endpoint) -> Types.State
  key = Endpoint.key(endpoint)
  return state if own?(state, key)

  listed = state.with(found: state.found.put(key, endpoint))
  return listed if state.peers.has_key?(state.names.get(key).unwrap_or(""))

  dial(listed, state.kept.get(key).unwrap_or(endpoint), quiet_reply())
end

# What the name gave and nothing links is forgotten, so that the addresses of nodes that come and go (a new one at each
# start) do not pile up.
def unfound(state: Types.State, key: String) -> Types.State
  return state if state.kept.has_key?(key) or state.peers.has_key?(state.names.get(key).unwrap_or(""))

  state.with(found: state.found.delete(key), names: state.names.delete(key))
end

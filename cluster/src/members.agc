## The actor of a node: it knows the peers by name, decides which of two links to the same peer stays, and starts the
## tasks that dial. The listener is a task of its own (src/listener.agc), and each connection is a task (src/link.agc).

import Actor from "std/actor"
import Endpoint from "endpoint"
import Link from "link"
import Types from "types"

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

def start_state(options: Types.Options, counts: ATS[String, Int]) -> Types.State
  inbox: Channel[Types.Msg] = Actor.inbox
  Types.State(
    config: config(options, inbox.address, counts),
    peers: {},
    dialing: {},
    mailboxes: {},
    watchers: [],
    kept: {},
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
  count = state.peers.size + state.dialing.size + state.timers.size
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
  kept = state.with(peers: state.peers.put(peer.name, peer), delays: state.delays.delete(peer.endpoint))
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

  down(retry(state.with(peers: state.peers.delete(peer.name)), peer.endpoint), peer.name)
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
    listed = current.with(kept: current.kept.put(Endpoint.key(endpoint), endpoint))
    current = dial(listed, endpoint, quiet_reply())
  end

  current
end

def retried(state: Types.State, key: String, result: Result[String]) -> Types.State
  case result
    ok(_) -> state
    error(_) -> retry(state, key)
  end
end

# The wait before the next dial of a peer of the list: `reconnect_ms` at first, and twice the last one after each
# failure, up to `reconnect_max_ms`. A peer that is not of the list is not dialed again.
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
  timer = Task.spawn(&Link.redial, Link.Redial(node: config.node, key: key, wait_ms: delay))
  state.with(delays: state.delays.put(key, delay), timers: state.timers.put(key, timer))
end

def redial(state: Types.State, key: String) -> Types.State
  waited = state.with(timers: state.timers.delete(key))
  case state.kept.get(key)
    some(endpoint) -> dial(waited, endpoint, quiet_reply())
    none -> waited
  end
end

# Nobody waits for the answer of a dial that the node makes by itself.
def quiet_reply() -> Channel[Result[String]] = Channel.new(1)

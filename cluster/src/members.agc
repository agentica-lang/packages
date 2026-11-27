## The actor of a node: it knows the peers by name, decides which of two links to the same peer stays, and starts the
## tasks that dial. The listener is a task of its own (src/listener.agc), and each connection is a task (src/link.agc).

import Actor from "std/actor"
import Endpoint from "endpoint"
import Link from "link"
import Types from "types"

## The behaviour of the actor of a node with these options.
def behaviour(options: Types.Options, pending: ATS[String, Int]) -> Actor.Behaviour[Types.State, Types.Msg]
  Actor.Behaviour(init: -> { start_state(options, pending) }, handle: &handle, terminate: some(&terminate))
end

## What the tasks of a node share, once the address of its actor is known. `pending` counts the connections that are in
## their handshake, for all the tasks of the node.
def config(options: Types.Options, node: Address[Types.Msg], pending: ATS[String, Int]) -> Types.Config
  Types.Config(
    name: options.name,
    cookie: options.cookie.bytes,
    connect_ms: options.connect_ms,
    max_pending: options.max_pending,
    pending: pending,
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

def start_state(options: Types.Options, pending: ATS[String, Int]) -> Types.State
  inbox: Channel[Types.Msg] = Actor.inbox
  Types.State(config: config(options, inbox.address, pending), peers: {}, dialing: {}, refused: 0)
end

def handle(state: Types.State, message: Types.Msg) -> Actor.Step[Types.State]
  case message
    Types.Msg.Linked(peer, reply) -> Actor.continue(link(state, peer, reply))
    Types.Msg.Closed(name, id) -> Actor.continue(unlink(state, name, id))
    Types.Msg.Dial(endpoint, reply) -> Actor.continue(dial(state, endpoint, reply))
    Types.Msg.Dialed(key, result) -> Actor.continue(dialed(state, key, result))
    Types.Msg.Refused -> Actor.continue(state.with(refused: state.refused + 1))
    Types.Msg.Names(reply) -> answer(state, reply, state.peers.keys.sort)
    Types.Msg.Refusals(reply) -> answer(state, reply, state.refused)
  end
end

def answer[T](state: Types.State, reply: Channel[T], value: T) -> Actor.Step[Types.State]
  _ = Actor.reply(reply, value)
  Actor.continue(state)
end

# Every link and every dial in flight ends with the node.
def terminate(state: Types.State) -> Void
  for peer in state.peers.values
    Task.cancel(peer.link)
  end

  for dialing in state.dialing.values
    Task.cancel(dialing.task)
  end
end

def link(state: Types.State, peer: Types.Peer, reply: Channel[Bool]) -> Types.State
  current = state.peers.get(peer.name)
  case current
    none -> keep(state, peer, reply)
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

def keep(state: Types.State, peer: Types.Peer, reply: Channel[Bool]) -> Types.State
  _ = Actor.reply(reply, true)
  state.with(peers: state.peers.put(peer.name, peer))
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

  state.with(peers: state.peers.delete(peer.name))
end

# An address that this node dialed and that is linked answers at once; one that is being dialed adds the caller
# to those
# that wait; any other starts a task that dials.
def dial(state: Types.State, endpoint: Types.Endpoint, reply: Channel[Result[String]]) -> Types.State
  key = Endpoint.key(endpoint)
  case linked_at(state, key)
    ok(peer) -> answered(state, reply, peer, endpoint)
    error(_) -> dial_new(state, key, endpoint, reply)
  end
end

def linked_at(state: Types.State, key: String) -> Result[Types.Peer]
  state.peers.values.find { |peer| peer.endpoint == key }
end

def answered(
  state: Types.State,
  reply: Channel[Result[String]],
  peer: Types.Peer,
  endpoint: Types.Endpoint,
) -> Types.State
  if endpoint.node.empty? or endpoint.node == peer.name
    _ = reply.send(ok(peer.name), 0)
  else
    _ = reply.send(error("cluster: that address answers under another name", kind: Types.REFUSED), 0)
  end

  state
end

def dial_new(state: Types.State, key: String, endpoint: Types.Endpoint, reply: Channel[Result[String]]) -> Types.State
  case state.dialing.get(key)
    some(dialing) -> state.with(dialing: state.dialing.put(key, dialing.with(waiters: dialing.waiters.push(reply))))
    none ->
      task = Task.spawn(&Link.dial, Link.Dial(config: state.config, endpoint: endpoint))
      state.with(dialing: state.dialing.put(key, Types.Dialing(task: task, waiters: [reply])))
  end
end

def dialed(state: Types.State, key: String, result: Result[String]) -> Types.State
  case state.dialing.get(key)
    some(dialing) ->
      for waiter in dialing.waiters
        _ = waiter.send(result, 0)
      end

      state.with(dialing: state.dialing.delete(key))
    none -> state
  end
end

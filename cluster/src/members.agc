## The actor of a node: it knows the peers by name, decides which of two links to the same peer stays, and starts the
## tasks that dial. The listener is a task of its own (`accept_loop`), and each connection is a task (src/link.agc).

import Actor from "std/actor"
import Link from "link"
import Types from "types"

## The behaviour of the actor of a node with these options.
def behaviour(options: Types.Options) -> Actor.Behaviour[Types.State, Types.Msg]
  Actor.Behaviour(init: -> { start_state(options) }, handle: &handle, terminate: some(&terminate))
end

## What the tasks of a node share, once the address of its actor is known.
def config(options: Types.Options, node: Address[Types.Msg]) -> Types.Config
  Types.Config(
    name: options.name,
    cookie: options.cookie.bytes,
    connect_ms: options.connect_ms,
    max_frame_bytes: options.max_frame_bytes,
    node: node,
  )
end

private

def start_state(options: Types.Options) -> Types.State
  inbox: Channel[Types.Msg] = Actor.inbox
  Types.State(config: config(options, inbox.address), peers: {}, refused: 0)
end

def handle(state: Types.State, message: Types.Msg) -> Actor.Step[Types.State]
  case message
    Types.Msg.Linked(peer, reply) -> Actor.continue(link(state, peer, reply))
    Types.Msg.Closed(name, id) -> Actor.continue(unlink(state, name, id))
    Types.Msg.Dial(endpoint, reply) -> Actor.continue(dial(state, endpoint, reply))
    Types.Msg.Refused -> Actor.continue(state.with(refused: state.refused + 1))
    Types.Msg.Names(reply) -> answer(state, reply, state.peers.keys.sort)
    Types.Msg.Refusals(reply) -> answer(state, reply, state.refused)
  end
end

def answer[T](state: Types.State, reply: Channel[T], value: T) -> Actor.Step[Types.State]
  _ = Actor.reply(reply, value)
  Actor.continue(state)
end

def terminate(state: Types.State) -> Void
  for peer in state.peers.values
    Task.cancel(peer.link)
  end
end

# Two nodes that connect to each other at the same moment make two links. Both keep the one that the smaller name
# dialed, so they agree with no talk; a second link dialed by the same side replaces the first, which may be stale.
def link(state: Types.State, peer: Types.Peer, reply: Channel[Bool]) -> Types.State
  current = state.peers.get(peer.name)
  case current
    none -> keep(state, peer, reply)
    some(old) ->
      if replaces?(peer, old)
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

def replaces?(peer: Types.Peer, old: Types.Peer) -> Bool
  peer.dialer == old.dialer or peer.dialer.compare(old.dialer) < 0
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

def dial(state: Types.State, endpoint: Types.Endpoint, reply: Channel[Result[String]]) -> Types.State
  _ = Task.spawn(&Link.dial, Link.Dial(config: state.config, endpoint: endpoint, reply: reply))
  state
end

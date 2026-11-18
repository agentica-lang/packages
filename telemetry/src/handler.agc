## The actor of one handler. It takes its events one at a time, so a slow handler delays only its own queue, and a
## handler that fails ends its own actor and tells the hub.

import Actor from "std/actor"
import Types from "types"

## A handler's actor: where to send it events, and its task (the hub monitors it and can cancel it).
struct Started
  address: Address[Types.Msg]
  task: Task[Result[Void]]
end

## Starts the actor of the handler `id`, a child of the task that calls this (the hub). A queue of `capacity` events
## refuses more. An error of the handler goes to `hub` as a `Failed` message.
def start(id: String, call: Fn[Types.Event, Result[Void]], capacity: Int, hub: Address[Types.HubMsg]) -> Started
  behaviour: Actor.Behaviour[State, Types.Msg] = Actor.Behaviour(
    init: -> { State(id: id, call: call, hub: hub) },
    handle: &handle,
  )

  actor = Actor.start(behaviour, Actor.Options(capacity: capacity))
  Started(address: actor.address, task: actor.task)
end

private

# How long a handler waits for room in the inbox of the hub, which only gets attaches, detaches and failures.
HUB_MS = 5_000

# `failed` is set once the hub was told: the actor then ignores events and answers barriers until the hub cancels
# it, so
# the hub hears of the failure from the message and not from the end of the task.
struct State
  id: String
  call: Fn[Types.Event, Result[Void]]
  hub: Address[Types.HubMsg]
  failed: Bool = false
end

def handle(state: State, message: Types.Msg) -> Actor.Step[State]
  case message
    Types.Msg.Deliver(event) -> deliver(state, event)
    Types.Msg.Barrier(ack) ->
      _ = Actor.reply(ack, true)
      Actor.continue(state)
  end
end

def deliver(state: State, event: Types.Event) -> Actor.Step[State]
  return Actor.continue(state) if state.failed

  case state.call.call(event)
    ok(_) -> Actor.continue(state)
    error(e) -> failed(state, e.kind)
  end
end

# When the hub cannot be told the actor ends, and the hub sees the end of its task.
def failed(state: State, kind: String) -> Actor.Step[State]
  failure = Types.Failure(id: state.id, task: Task.current().id, kind: kind)
  case Actor.cast(state.hub, Types.HubMsg.Failed(failure), HUB_MS)
    ok(_) -> Actor.continue(state.with(failed: true))
    error(_) -> Actor.done(state)
  end
end

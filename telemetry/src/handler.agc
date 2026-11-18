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

# The hub has room for a message of a handler: it only gets attaches, detaches and failures.
HUB_MS = 5_000

struct State
  id: String
  call: Fn[Types.Event, Result[Void]]
  hub: Address[Types.HubMsg]
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
  case state.call.call(event)
    ok(_) -> Actor.continue(state)
    error(e) ->
      failure = Types.Failure(id: state.id, task: Task.current().id, kind: e.kind)
      _ = Actor.cast(state.hub, Types.HubMsg.Failed(failure), HUB_MS)
      Actor.done(state)
  end
end

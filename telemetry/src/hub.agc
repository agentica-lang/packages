## The hub: one actor that is the only writer of the routes. It starts the actor of each handler, so a handler lives as
## long as the hub and not as long as the task that attached it, and it watches them: a handler that returns an error
## or crashes is detached, with one warning that has the id and the kind and nothing of the event.

import Actor from "std/actor"
import Handler from "handler"
import Logger from "std/logger"
import Routes from "routes"
import Types from "types"

## Starts the hub, a child of the task that calls this. An error when one is running.
def start() -> Result[Void]
  return error("telemetry error: already started", kind: "telemetry.started") if running?()

  # A hub that was cancelled with its starter leaves its tables behind.
  Routes.reset()
  behaviour: Actor.Behaviour[State, Types.HubMsg] = Actor.Behaviour(init: &boot, handle: &handle)
  hub = Actor.start(behaviour, Actor.Options(capacity: INBOX))
  return ok() if Routes.HUB.put_new(Routes.HUB_KEY, hub.address)

  _ = Actor.stop(hub, STOP_MS)
  error("telemetry error: already started", kind: "telemetry.started")
end

## Attaches a handler: its actor starts and the routes of its patterns get it.
def attach(attachment: Types.Attachment) -> Result[Void] = ask(->(reply) { Types.HubMsg.Attach(attachment, reply) })

## Detaches a handler at once: the events in its queue are not delivered.
def detach(id: String) -> Result[Void] = ask(->(reply) { Types.HubMsg.Detach(id, reply) })

## Ends the hub and every handler.
def stop() -> Result[Void] = ask(->(reply) { Types.HubMsg.Stop(reply) })

## True when a hub answers.
def running?() -> Bool
  case Routes.hub()
    some(address) -> Actor.call(address, PING_MS, ->(reply) { Types.HubMsg.Ping(reply) }).ok?
    none -> false
  end
end

private

INBOX = 1_024
CALL_MS = 5_000
PING_MS = 1_000
STOP_MS = 1_000

struct Entry
  task: Task[Result[Void]]
  patterns: List[String]
end

struct State
  inbox: Channel[Types.HubMsg]
  handlers: Map[String, Entry]
  ids: Map[Int, String]
end

def boot() -> State
  inbox: Channel[Types.HubMsg] = Actor.inbox
  State(inbox: inbox, handlers: {}, ids: {})
end

def ask(make: Fn[Channel[Result[Void]], Types.HubMsg]) -> Result[Void]
  case Routes.hub()
    some(address) ->
      case Actor.call(address, CALL_MS, make)
        ok(answer) -> answer
        error(e) -> unreachable(e)
      end

    none -> error("telemetry error: not started", kind: "telemetry.not_started")
  end
end

def unreachable(e: Error) -> Result[Void]
  return error("telemetry error: not started", kind: "telemetry.not_started") if e.is_a?("channel.gone")

  error("telemetry error: the hub did not answer in #{CALL_MS} ms", kind: "telemetry.timeout")
end

def handle(state: State, message: Types.HubMsg) -> Actor.Step[State]
  case message
    Types.HubMsg.Attach(attachment, reply) -> attached(state, attachment, reply)
    Types.HubMsg.Detach(id, reply) -> detached(state, id, reply)
    Types.HubMsg.Failed(failure) -> failed(state, failure)
    Types.HubMsg.Down(down) -> down(state, down)
    Types.HubMsg.Ping(reply) ->
      _ = Actor.reply(reply, true)
      Actor.continue(state)
    Types.HubMsg.Stop(reply) -> stopped(state, reply)
  end
end

def attached(state: State, attachment: Types.Attachment, reply: Channel[Result[Void]]) -> Actor.Step[State]
  if state.handlers.has_key?(attachment.id)
    _ = Actor.reply(reply, error("telemetry error: the id #{attachment.id} is in use", kind: "telemetry.duplicate"))

    return Actor.continue(state)
  end

  started = Handler.start(attachment.id, attachment.handler, attachment.capacity, state.inbox.address)
  Task.monitor(started.task, state.inbox) do |down| Types.HubMsg.Down(down) end
  Routes.add(attachment.id, attachment.patterns, started.address)
  _ = Actor.reply(reply, ok())
  entry = Entry(task: started.task, patterns: attachment.patterns)
  Actor.continue(
    state.with(handlers: state.handlers.put(attachment.id, entry), ids: state.ids.put(started.task.id, attachment.id)),
  )
end

def detached(state: State, id: String, reply: Channel[Result[Void]]) -> Actor.Step[State]
  if not state.handlers.has_key?(id)
    _ = Actor.reply(reply, error("telemetry error: no handler has the id #{id}", kind: "telemetry.unknown"))
    return Actor.continue(state)
  end

  _ = Actor.reply(reply, ok())
  Actor.continue(forget(state, id))
end

# A handler told the hub it failed. A notice from an older handler of the same id is not this one's.
def failed(state: State, failure: Types.Failure) -> Actor.Step[State]
  case state.handlers.get(failure.id)
    some(entry) if entry.task.id == failure.task -> Actor.continue(drop(state, failure.id, failure.kind))
    _ -> Actor.continue(state)
  end
end

# The end of a handler's task. A task that returned is a `Failed` in the inbox (or was detached), and a cancel that the
# hub made finds no id.
def down(state: State, down: TaskDown) -> Actor.Step[State]
  case state.ids.get(down.task_id)
    some(id) ->
      case down.reason
        TaskExit.Ok -> Actor.continue(state)
        TaskExit.Crashed -> Actor.continue(drop(state, id, down.code))
        TaskExit.Cancelled -> Actor.continue(drop(state, id, "cancelled"))
      end

    none -> Actor.continue(state)
  end
end

def stopped(state: State, reply: Channel[Result[Void]]) -> Actor.Step[State]
  for id in state.handlers.keys()
    _ = forget(state, id)
  end

  Routes.clear()
  Routes.HUB.delete(Routes.HUB_KEY)
  _ = Actor.reply(reply, ok())
  Actor.done(state)
end

# Detaches and says why: only the id and the kind, never what the event held.
def drop(state: State, id: String, kind: String) -> State
  Logger.warning("telemetry handler detached", {"id": id, "kind": kind})
  forget(state, id)
end

def forget(state: State, id: String) -> State
  case state.handlers.get(id)
    some(entry) ->
      Routes.remove(id, entry.patterns)
      Task.cancel(entry.task)
      state.with(handlers: state.handlers.delete(id), ids: state.ids.delete(entry.task.id))
    none -> state
  end
end

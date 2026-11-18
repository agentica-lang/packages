## The hub: one actor that is the only writer of the routes. It starts the actor of each handler, so a handler lives as
## long as the hub and not as long as the task that attached it, and it watches them: a handler that returns an error
## or crashes is detached, with one warning that has the id and the kind and nothing of the event.

import Actor from "std/actor"
import Handler from "handler"
import Logger from "std/logger"
import Names from "names"
import Routes from "routes"
import Types from "types"

## Starts the hub, a child of the task that calls this. Only one start runs at a time: a start that finds another
## running, or a hub that answers (or is too busy to), gives `telemetry.started`.
def start() -> Result[Void]
  return started() if not Routes.STARTING.put_new(Routes.HUB_KEY, 1)

  made = launch()
  Routes.STARTING.delete(Routes.HUB_KEY)
  made
end

## Attaches a handler: its actor starts and the routes of its patterns get it.
def attach(attachment: Types.Attachment) -> Result[Void] = ask(->(reply) { Types.HubMsg.Attach(attachment, reply) })

## Detaches a handler at once: the events in its queue are not delivered.
def detach(id: String) -> Result[Void] = ask(->(reply) { Types.HubMsg.Detach(id, reply) })

## Ends the hub and every handler.
def stop() -> Result[Void] = ask(->(reply) { Types.HubMsg.Stop(reply) })

## True when the hub that the tables name has ended, as a hub does with the task that started it: the tables are then
## cleared. A hub that is only busy is not gone.
def gone?() -> Bool
  case Routes.hub()
    some(address) -> ended?(address, pulse(address, PING_MS))
    none -> false
  end
end

## Gives a barrier through the inbox of the hub: what the handlers told it before this call has been handled when it
## returns. Does not wait more than `timeout_ms`.
def sync(timeout_ms: Int) -> Void
  case Routes.hub()
    some(address) ->
      _ = pulse(address, [timeout_ms, 1].max.unwrap!)
      nil
    none -> nil
  end
end

private

INBOX = 1_024
CALL_MS = 5_000
PING_MS = 1_000

enum Pulse
  Alive
  Gone
  Busy
end

struct Entry
  task: Task[Result[Void]]
  patterns: List[String]
end

struct State
  inbox: Channel[Types.HubMsg]
  handlers: Map[String, Entry]
  ids: Map[Int, String]
end

def started() -> Result[Void] = error("telemetry error: already started", kind: "telemetry.started")

def not_started[T]() -> Result[T] = error("telemetry error: not started", kind: "telemetry.not_started")

# Starts the actor, unless a hub is there. The tables of a hub that ended are cleared first.
def launch() -> Result[Void]
  case Routes.hub()
    some(address) -> return started() if not ended?(address, pulse(address, PING_MS))
    none -> nil
  end

  behaviour: Actor.Behaviour[State, Types.HubMsg] = Actor.Behaviour(init: &boot, handle: &handle)
  hub = Actor.start(behaviour, Actor.Options(capacity: INBOX))
  Routes.HUB.put(Routes.HUB_KEY, hub.address)
  ok()
end

# A hub that does not answer in time is busy, not gone: only a closed inbox says it ended.
def pulse(address: Address[Types.HubMsg], timeout_ms: Int) -> Pulse
  case Actor.call(address, timeout_ms, ->(reply) { Types.HubMsg.Ping(reply) })
    ok(_) -> Pulse.Alive
    error(e) if e.is_a?("channel.gone") -> Pulse.Gone
    error(_) -> Pulse.Busy
  end
end

def ended?(address: Address[Types.HubMsg], pulse: Pulse) -> Bool
  case pulse
    Pulse.Gone ->
      Routes.forget_hub(address)
      true
    Pulse.Alive -> false
    Pulse.Busy -> false
  end
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
        error(e) -> ask_error(address, e)
      end

    none -> not_started()
  end
end

# An answer that did not come: the hub ended (and its tables are cleared), or it took more than `CALL_MS`, in
# which case
# the call may still apply later.
def ask_error(address: Address[Types.HubMsg], e: Error) -> Result[Void]
  if e.is_a?("channel.gone")
    Routes.forget_hub(address)
    return not_started()
  end

  error("telemetry error: the hub did not answer in #{CALL_MS} ms", kind: "telemetry.timeout")
end

def handle(state: State, message: Types.HubMsg) -> Actor.Step[State]
  case message
    Types.HubMsg.Attach(attachment, reply) -> attached(state, attachment, reply)
    Types.HubMsg.Detach(id, reply) -> detached(state, id, reply)
    Types.HubMsg.Failed(failure) -> failed(state, failure)
    Types.HubMsg.Down(notice) -> down(state, notice)
    Types.HubMsg.Ping(reply) ->
      _ = Actor.reply(reply, true)
      Actor.continue(state)
    Types.HubMsg.Stop(reply) -> stopped(state, reply)
  end
end

def attached(state: State, attachment: Types.Attachment, reply: Channel[Result[Void]]) -> Actor.Step[State]
  # Checked again: a start of a handler that crashed the hub would end every handler.
  checked = Names.check_attach(attachment.id, attachment.patterns, Types.Options(capacity: attachment.capacity))
  if not checked.ok?
    _ = Actor.reply(reply, checked)
    return Actor.continue(state)
  end

  if state.handlers.has_key?(attachment.id)
    _ = Actor.reply(reply, error("telemetry error: the id #{attachment.id} is in use", kind: "telemetry.duplicate"))

    return Actor.continue(state)
  end

  started = Handler.start(attachment.id, attachment.handler, attachment.capacity, state.inbox.address)
  Task.monitor(started.task, state.inbox) do |down| Types.HubMsg.Down(down) end
  Routes.add(attachment.id, attachment.patterns, started.address, started.task.id)
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

  # The routes go before the answer, so no event is routed to the handler once `detach` has returned.
  forgotten = forget(state, id)
  _ = Actor.reply(reply, ok())
  Actor.continue(forgotten)
end

# A handler told the hub it failed. A notice from an older handler of the same id is not this one's.
def failed(state: State, failure: Types.Failure) -> Actor.Step[State]
  case state.handlers.get(failure.id)
    some(entry) if entry.task.id == failure.task -> Actor.continue(drop(state, failure.id, failure.kind))
    _ -> Actor.continue(state)
  end
end

# The end of a handler's task. A cancel that the hub made finds no id, since `forget` took it. A task that returned
# while it was still routed is a handler that could not tell the hub of its failure.
def down(state: State, notice: TaskDown) -> Actor.Step[State]
  case state.ids.get(notice.task_id)
    some(id) ->
      case notice.reason
        TaskExit.Ok -> Actor.continue(drop(state, id, "ended"))
        TaskExit.Crashed -> Actor.continue(drop(state, id, notice.code))
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
      Routes.remove(id, entry.patterns, entry.task.id)
      Task.cancel(entry.task)
      state.with(handlers: state.handlers.delete(id), ids: state.ids.delete(entry.task.id))
    none -> state
  end
end

## `flush`: a barrier through the queue of every handler. The handler answers it after the events that were queued
## before it, so when it is answered those events were handled.

import Actor from "std/actor"
import Routes from "routes"
import Types from "types"

## Waits at most `timeout_ms` until each handler has handled what was queued when the barrier reached it. A handler
## that is detached in the meantime has nothing to wait for.
def barrier(timeout_ms: Int) -> Result[Void]
  deadline = Time.monotonic_ms + timeout_ms
  waiting: List[Pending] = []
  for id in Routes.handler_ids()
    case Routes.HANDLERS.get(id)
      ok(address) -> waiting = waiting.push(try queue(id, address, deadline))
      error(_) -> nil
    end
  end

  for pending in waiting
    try answered(pending, deadline)
  end

  ok()
end

private

# How long to wait for an answer before looking again whether the handler is still attached.
LOOK_MS = 20

struct Pending
  id: String
  ack: Channel[Bool]
end

def queue(id: String, address: Address[Types.Msg], deadline: Int) -> Result[Pending]
  ack: Channel[Bool] = Channel.new(1)
  case Actor.cast(address, Types.Msg.Barrier(ack), [deadline - Time.monotonic_ms, 0].max.unwrap!)
    ok(_) -> ok(Pending(id: id, ack: ack))
    error(e) if e.is_a?("channel.timeout") -> late(deadline)
    error(_) -> ok(Pending(id: id, ack: ack))
  end
end

def answered(pending: Pending, deadline: Int) -> Result[Void]
  while Routes.HANDLERS.has_key?(pending.id)
    left = deadline - Time.monotonic_ms
    return late(deadline) if left <= 0
    return ok() if pending.ack.recv([left, LOOK_MS].min.unwrap!).ok?
  end

  ok()
end

def late[T](deadline: Int) -> Result[T]
  error("telemetry error: a handler did not catch up in time", kind: "telemetry.timeout")
end

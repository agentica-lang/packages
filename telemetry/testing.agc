## Events for a test: `capture` attaches a handler that keeps the events that match, and `events` gives what was
## emitted since the last call, after a `flush`, so a test never sleeps to wait for the async delivery.
##
## There are two ways to use it. In a program or a unit test that owns its tasks, start the hub with `Telemetry.start`,
## `capture`, emit, read with `events`, then `stop` the capture. In a BDD step, or any test that must leave no task
## running, `session` does all of it in one call: it starts the hub when none runs, captures, runs the body, detaches,
## and ends the hub and waits for its tasks to end, so nothing is left running when it returns. That wait is on the
## process-wide count of tasks: a body that leaves tasks of its own, or other tasks that run meanwhile, can make it wait
## and end with `telemetry.timeout`.
##
## Errors have a kind: those of `Telemetry`, `telemetry.unknown` when `events` reads a capture that is not attached, and
## `telemetry.lost` when events did not fit (`events` says how many).
##
## A session is for one task at a time: two sessions that overlap in time share the hub, and the first to end stops it.

import Telemetry from "telemetry"

## The most events that a capture keeps between two reads, unless `capture` is given another room.
ROOM = 4_096

## A running capture: read it with `events`, and `stop` it.
struct Capture
  id: String
  events: Channel[Telemetry.Event]
  lost: ATS[String, Int]
end

## Attaches a handler under a new id for the events that match `patterns` (as `Telemetry.attach`), with room for `room`
## events between two reads. Needs a running hub.
def capture(patterns: List[String], room: Int = ROOM) -> Result[Capture]
  id = "telemetry_capture#{IDS.add("last", 1)}"
  events: Channel[Telemetry.Event] = Channel.new(room)
  lost: ATS[String, Int] = ATS.new()
  try Telemetry.attach(id, patterns, ->(event) { keep(events, lost, event) }, Telemetry.Options(capacity: room))
  ok(Capture(id: id, events: events, lost: lost))
end

## Waits until the handler has handled everything emitted before this call (a `flush`), and gives the events since the
## last call, in the order the handler got them: the events of one task are in order. Two errors: `telemetry.unknown`
## when the capture is not attached any more (it was stopped, or the hub ended), and `telemetry.lost` when events did
## not fit since the last read, since a test must not miss one without knowing. The `lost` error says how many; the
## events that were kept are dropped with it, and the next read starts clean.
def events(capture: Capture, timeout_ms: Int = 5_000) -> Result[List[Telemetry.Event]]
  try Telemetry.flush(timeout_ms)
  if not Telemetry.handlers().include?(capture.id)
    return error("telemetry testing: #{capture.id} is not attached", kind: "telemetry.unknown")
  end

  found = drain(capture.events)
  lost = missed(capture)
  if lost > 0
    return error("telemetry testing: #{lost} events did not fit, give capture more room", kind: "telemetry.lost")
  end

  ok(found)
end

## Detaches the handler. Read the events first: after this, `events` is an error `telemetry.unknown`.
def stop(capture: Capture) -> Result[Void] = Telemetry.detach(capture.id)

## Runs `body` with a capture of `patterns`, in one call that leaves no task running. A hub that runs already (an
## app's) is used and left running; otherwise the session starts one and ends it. The result is the body's.
def session[T](patterns: List[String], body: Fn[Capture, Result[T]], room: Int = ROOM) -> Result[T]
  running = Task.pending_count()
  started = Telemetry.start().ok?
  result = captured(patterns, room, body)
  ended = finish(started, running)
  if result.ok?
    try ended
  end

  result
end

private

IDS: ATS[String, Int] = ATS.new()
ENDED_MS = 2_000

# The handler of a capture. A full channel is counted, not an error, since an error would detach the handler.
def keep(events: Channel[Telemetry.Event], lost: ATS[String, Int], event: Telemetry.Event) -> Result[Void]
  if not events.send(event, 0).ok?
    _ = lost.add("lost", 1)
  end

  ok()
end

# The events that did not fit since the last call: the handler's count, and the drops of its queue. Both are taken
# off, so the next read counts from here.
def missed(capture: Capture) -> Int
  kept = capture.lost.get("lost").unwrap_or(0)
  _ = capture.lost.add("lost", 0 - kept)
  dropped = Telemetry.dropped(capture.id)
  seen = capture.lost.get("seen").unwrap_or(0)
  _ = capture.lost.add("seen", dropped - seen)
  kept + dropped - seen
end

def drain(events: Channel[Telemetry.Event]) -> List[Telemetry.Event]
  found: List[Telemetry.Event] = []
  while true
    case events.recv(0)
      ok(event) -> found = found.push(event)
      error(_) -> break
    end
  end

  found
end

def captured[T](patterns: List[String], room: Int, body: Fn[Capture, Result[T]]) -> Result[T]
  made = try capture(patterns, room)
  result = body.call(made)
  _ = stop(made)
  result
end

# Ends the hub that the session started, and waits (a few ms at a time, at most `ENDED_MS`) for its tasks: the hub
# answers `stop` before its task has ended, and a step or a test must not return with tasks running.
def finish(started: Bool, running: Int) -> Result[Void]
  return ok() if not started

  _ = Telemetry.stop()
  waited = 0
  while Task.pending_count() > running and waited < ENDED_MS
    Task.sleep(1)
    waited += 1
  end

  if Task.pending_count() > running
    return error("telemetry testing: the tasks of the hub did not end", kind: "telemetry.timeout")
  end

  ok()
end

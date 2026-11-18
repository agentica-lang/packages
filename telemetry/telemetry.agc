## Events for numbers, as `std/logger` is for text: a library calls `execute` to say that something happened, and an
## app attaches handlers to count it, log it or send it away. With no handler attached `execute` costs one table read.
##
## An event is a dotted name, two maps of measurements (`ints` and `floats`) and a map of strings (`metadata`). A
## handler is attached to patterns, each a name or the first words of one (`"jobs"` hears `jobs.job.stop`, not
## `jobs_extra.x`), or `"*"` for all, and it runs in an actor of its own: `execute` never waits for it. When the queue
## of a handler is full the event is dropped and counted (`dropped`). A handler that returns an error or crashes is
## detached at once, with one `Logger.warning` that names its id and the kind.
##
## Errors have a kind: `telemetry.not_started`, `telemetry.started`, `telemetry.duplicate`, `telemetry.unknown`,
## `telemetry.timeout`, `telemetry.in_handler` (`flush` or `stop` called by a handler, which would wait for itself),
## and the builtin `argument` for a bad id, pattern or capacity (1 to 1_048_576). A call that gives `telemetry.timeout`
## may still take effect later: the hub did not answer in time, not refuse.
##
## `Telemetry.start` starts the hub as a child of the task that calls it: call it in `main`.

import Actor from "std/actor"
import Flush from "src/flush"
import Hub from "src/hub"
import Names from "src/names"
import Routes from "src/routes"
import Types from "src/types"

export Types.Event
export Types.Options

## Starts the hub. Fails with `telemetry.started` when one runs, or another start is running. A hub that ended with
## the task that started it is replaced.
def start() -> Result[Void] = Hub.start()

## Waits at most `timeout_ms` for the handlers to catch up (`flush`), then detaches them all and ends the hub.
## Fails with `telemetry.not_started` when no hub runs, and with `telemetry.timeout` when the drain ran out of time
## (the hub ends anyway).
def stop(timeout_ms: Int = 5_000) -> Result[Void]
  try Flush.outside_handler("stop")
  return error("telemetry error: not started", kind: "telemetry.not_started") if Routes.hub().none?

  drained = Flush.barrier(timeout_ms)
  try Hub.stop()
  drained
end

## Says that `name` happened. It never fails and never waits: each handler that hears it gets the event in its queue,
## or, when its queue is full, a count in `dropped`. With no handler attached it does nothing else.
def execute(
  name: String,
  ints: Map[String, Int] = {},
  floats: Map[String, Float] = {},
  metadata: Map[String, String] = {},
) -> Void
  return if Routes.idle?()

  routes = Routes.matching(name)
  return if routes.empty?

  event = Types.Event(
    name: name,
    ints: ints,
    floats: floats,
    metadata: metadata,
    time_ms: Time.now_ms,
    task: Task.current().id,
  )

  for route in routes
    deliver(route, event)
  end
end

## True when `execute` of this name reaches a handler: a guard for arguments that cost something to build.
def enabled?(name: String) -> Bool = Routes.heard?(name)

## Attaches a handler under `id` to the events that match any of `events` (see the top of this page). A handler
## returns an error to say it failed, and is detached. Fails with `argument` for a bad id or pattern, with
## `telemetry.duplicate` when the id is in use and with `telemetry.not_started` before `start`.
def attach(
  id: String,
  events: List[String],
  handler: Fn[Types.Event, Result[Void]],
  options: Types.Options = Types.Options(),
) -> Result[Void]
  try Names.check_attach(id, events, options)
  Hub.attach(Types.Attachment(id: id, patterns: events, handler: handler, capacity: options.capacity))
end

## Detaches the handler `id`; the events in its queue are not delivered. Fails with `telemetry.unknown`.
def detach(id: String) -> Result[Void] = Hub.detach(id)

## The ids of the attached handlers, sorted.
def handlers() -> List[String] = Routes.handler_ids()

## How many events the handler `id` dropped because its queue was full. The count stays after the handler is detached,
## until the id is attached again; it is 0 for an id that was never attached.
def dropped(id: String) -> Int = Routes.DROPPED.get(id).unwrap_or(0)

## Waits at most `timeout_ms` until every handler has handled the events that were queued before the call. It is for
## tests and for the end of a program. Fails with `telemetry.timeout`.
def flush(timeout_ms: Int = 5_000) -> Result[Void] = Flush.barrier(timeout_ms)

private

def deliver(route: Types.Route, event: Types.Event) -> Void
  case Actor.cast(route.address, Types.Msg.Deliver(event), 0)
    error(e) if e.is_a?("channel.timeout") -> Routes.count_drop(route.id)
    _ -> nil
  end
end

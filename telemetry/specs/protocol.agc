## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the hub: a step cannot leave tasks running, and the hub and its handlers are tasks. It answers
## every request with one line, and the step program checks the line.

## How a handler acts: `mode` is `record`, `fail`, `crash`, `slow`, `flush`, `who`, `doomed` or `block`, and
## `capacity` is the size of its queue (0 for the default).
struct Handler
  id: String
  patterns: List[String]
  mode: String = "record"
  capacity: Int = 0
end

## An event to emit: a name, and a table of rows `kind`, `key`, `value` (after a header row), where the kind is `int`,
## `float` or `meta`.
struct Emit
  name: String
  table: List[List[String]] = []
end

## `count` events with the name `name`.
struct Flood
  name: String
  count: Int
end

## `tasks` tasks that do something `events` times each.
struct Load
  tasks: Int
  events: Int
end

## `count` handlers that are cancelled at once, and then `handler`; `name` is the event that each of them gets.
struct Churn
  handler: Handler
  name: String
  count: Int
end

## A span with the metadata in the rows of `table` (after a header row), whose body does what `mode` says (`ok`,
## `error` or `crash`) after `sleep_ms` ms.
struct SpanRun
  name: String
  mode: String
  sleep_ms: Int
  table: List[List[String]] = []
end

## A capture of the testing helper under the name `id`, with room for `room` events (0 for the default).
struct Watch
  id: String
  patterns: List[String]
  room: Int = 0
end

## A session of the testing helper that captures `patterns` and emits `name`.
struct Session
  patterns: List[String]
  name: String
end

## A request, one for each thing a step asks of the driver. A `String` is the id of a handler or a capture, unless the
## comment says it is a name.
enum Request
  Start
  Stop(Int)
  Attach(Handler)
  Detach(String)
  Execute(Emit)
  Flood(Flood)
  Flush
  Release(String)
  Handlers
  Enabled(String)
  Dropped(String)
  Log(String)
  Warnings
  Idle
  Stress(Load)
  Starts(Int)
  StartInTask
  CancelStarter
  Churn(Churn)
  ForgeFailure(String)
  ForgeEnd(String)
  FailuresGone(Int)
  DetachesAtOnce(Int)
  StaleClaim
  BusyHub
  ForgetOther
  Claims
  ForgetUnderClaim
  FlushBudget
  SecondHub
  Span(SpanRun)
  SpanStress(Load)
  Capture(Watch)
  Captured(String)
  CaptureStop(String)
  CaptureRace(Int)
  CaptureStress(Load)
  Session(Session)
  Steps(String)
end

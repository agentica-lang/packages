## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the hub: a step cannot leave tasks running, and the hub and its handlers are tasks. It answers
## every request with one line, and the step program checks the line.

## What a handler does with an event: `Record` records it, `Fail` returns an error, `Crash` crashes, `Slow` pauses
## first, `Flush` calls `flush` and records the answer, `Who` records its task, and `Block` records it and waits for
## `Release`.
enum Acts
  Record
  Fail
  Crash
  Slow
  Flush
  Who
  Block
end

## A handler: what it does, and `capacity`, the size of its queue (0 for the default).
struct Handler
  id: String
  patterns: List[String]
  acts: Acts = Acts.Record
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

## What the body of a span does: returns 42, returns an error of the kind `span.bad`, or crashes.
enum Body
  Returns
  Fails
  Crashes
end

## A span with the metadata in the rows of `table` (after a header row), whose body does what `body` says after
## `sleep_ms` ms.
struct SpanRun
  name: String
  body: Body
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

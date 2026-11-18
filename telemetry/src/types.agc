## The records and messages of the package.

## What a handler receives. A key is in one map only: `ints` for counts, durations (`_ns`) and sizes (`_bytes`),
## `floats` for fractions and ratios. `time_ms` is the wall clock at `execute`, and `task` the id of the task that
## called it.
struct Event
  name: String
  ints: Map[String, Int] = {}
  floats: Map[String, Float] = {}
  metadata: Map[String, String] = {}
  time_ms: Int = 0
  task: Int = 0
end

## What a handler may set when it is attached.
struct Options
  capacity: Int = 1_024
end

## What the actor of a handler takes: an event, or a barrier that `flush` sends and that is answered once every event
## before it was handled.
enum Msg
  Deliver(Event)
  Barrier(Channel[Bool])
end

## One handler on the route of a pattern.
struct Route
  id: String
  address: Address[Msg]
end

## What the hub takes: the attaches and detaches, what its handlers report, and the end.
enum HubMsg
  Attach(Attachment, Channel[Result[Void]])
  Detach(String, Channel[Result[Void]])
  Failed(Failure)
  Down(TaskDown)
  Ping(Channel[Bool])
  Stop(Channel[Result[Void]])
end

struct Attachment
  id: String
  patterns: List[String]
  handler: Fn[Event, Result[Void]]
  capacity: Int
end

# A handler that returned an error, from its own task: `task` tells the hub which instance it was.
struct Failure
  id: String
  task: Int
  kind: String
end

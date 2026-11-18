## Many tasks attach, detach and emit at the same time, on the hub of the driver. The run checks that:
## - a handler attached for the whole run gets exactly the events that were emitted, once each (after `flush`);
## - a handler with a small queue and slow work got and dropped exactly the events that were emitted, and did drop;
## - no handler gets an event twice;
## - no event is routed to a handler after its `detach` returned (a task emits events that name the handler it just
##   detached, and that handler must never see them);
## - of several attaches of one id at once, exactly one succeeds;
## - the hub is alive at the end and `handlers` lists what is left.

import Telemetry from "../telemetry"
import Testing from "../testing"

## Runs the stress with `workers` tasks that emit `events` events each, and gives `ok` or what went wrong.
def run(workers: Int, events: Int) -> String
  plan = Plan(events: events, seen: ATS.new(), totals: ATS.new(), twice: ATS.new(), late: ATS.new())
  everything = Telemetry.attach(
    "everything",
    ["*"],
    recorder(plan, "everything", 0),
    Telemetry.Options(capacity: ROOM),
  )

  small = Telemetry.attach("small", [TICK], recorder(plan, "small", 1), Telemetry.Options(capacity: SMALL))
  return "everything or small was not attached" if not (everything.ok? and small.ok?)

  tasks = (1..workers).to_a
  attached = Task.map(tasks, workers, TASK_MS, ->(worker) { attach_same(plan, worker) })
  winners = attached.select(->(result) { result.ok? }).size
  played = Task.map(tasks, workers, TASK_MS, ->(worker) { play(plan, worker) })
  failed = played.select(->(result) { not result.ok? }).size
  flushed = Telemetry.flush(TASK_MS)
  verdict(plan, Counted(workers: workers, winners: winners, failed: failed, flushed: flushed.ok?))
end

## Runs `workers` tasks that run `count` spans each at once, and gives `ok` when the handler got a start and a stop for
## each of the `workers * count` spans, and no two spans had the same `span_id`.
def run_spans(workers: Int, count: Int) -> String
  ids: ATS[String, Int] = ATS.new()
  note = ->(event: Telemetry.Event) { count_span(ids, event) }
  attached = Telemetry.attach("spans", ["stress.span"], note, Telemetry.Options(capacity: ROOM))
  return "the handler was not attached" if not attached.ok?

  tasks = (1..workers).to_a
  Task.map(tasks, workers, TASK_MS, ->(worker) { spans(worker, count) })
  flushed = Telemetry.flush(TASK_MS)
  return "flush ran out of time" if not flushed.ok?

  distinct = ids.keys().size
  once = ids.to_map().values().select(->(seen) { seen != 2 }).size
  return "#{distinct} span ids, not #{workers * count}" if distinct != workers * count
  return "#{once} spans did not get exactly a start and a stop" if once > 0

  "ok"
end

## Runs `workers` tasks that emit `count` events each at once, with a capture of the testing helper: `events` must give
## all of them, those of each task in order, and `stop` must detach the capture.
def run_capture(workers: Int, count: Int) -> String
  made = Testing.capture(["stress.cap"])
  return "the capture was not made" if not made.ok?

  taken = made.unwrap!
  tasks = (1..workers).to_a
  Task.map(tasks, workers, TASK_MS, ->(worker) { emit_all(worker, count) })
  found = Testing.events(taken)
  _ = Testing.stop(taken)
  return "events gave an error" if not found.ok?
  return "the capture is still attached" if not Telemetry.handlers().empty?

  in_order(found.unwrap!, workers * count)
end

private

TASK_MS = 60_000
TICK = "stress.tick"
# Events a task emits after it detached its handler.
LATE = 3
# Room for every event, for the handler that must get them all, and a queue that a slow handler cannot keep up with.
ROOM = 4_096
SMALL = 8

struct Plan
  events: Int
  seen: ATS[String, Int]
  totals: ATS[String, Int]
  twice: ATS[String, Int]
  late: ATS[String, Int]
end

struct Counted
  workers: Int
  winners: Int
  failed: Int
  flushed: Bool
end

# Counts what the handler `id` gets, how many times it got the same event (`seq`), and whether it got an event that was
# emitted after it was detached (the metadata `after` names the handler).
def recorder(plan: Plan, id: String, pause_ms: Int) -> Fn[Telemetry.Event, Result[Void]]
  ->(event) { note(plan, id, pause_ms, event) }
end

def note(plan: Plan, id: String, pause_ms: Int, event: Telemetry.Event) -> Result[Void]
  seq = event.ints.get("seq").unwrap_or(-1)
  _ = plan.totals.add(id, 1)
  if plan.seen.add("#{id}/#{seq}", 1) > 1
    _ = plan.twice.add(id, 1)
  end

  if event.metadata.get("after", "") == id
    _ = plan.late.add(id, 1)
  end

  Task.sleep(pause_ms)
  ok()
end

# Every task tries to take the id `same`; one gets it.
def attach_same(plan: Plan, _worker: Int) -> Result[Void] = Telemetry.attach("same", [TICK], recorder(plan, "same", 0))

# A task attaches a handler of its own, emits its events, detaches it, and emits more that name it.
def play(plan: Plan, worker: Int) -> Result[Void]
  id = "worker#{worker}"
  try Telemetry.attach(id, [TICK], recorder(plan, id, 0))
  base = worker * (plan.events + LATE)
  for i in 1..plan.events
    Telemetry.execute(TICK, {"seq": base + i}, {}, {"worker": "#{worker}"})
  end

  try Telemetry.detach(id)
  for i in 1..LATE
    Telemetry.execute(TICK, {"seq": base + plan.events + i}, {}, {"after": id})
  end

  ok()
end

def verdict(plan: Plan, counted: Counted) -> String
  total = counted.workers * (plan.events + LATE)
  got = plan.totals.get("everything").unwrap_or(0)
  small = plan.totals.get("small").unwrap_or(0)
  lost = Telemetry.dropped("small")
  return "#{counted.winners} attaches of one id succeeded, not 1" if counted.winners != 1
  return "#{counted.failed} tasks failed to attach or detach" if counted.failed > 0
  return "flush ran out of time" if not counted.flushed
  return "everything got #{got} events, not #{total}" if got != total
  return "small got #{small} and dropped #{lost}, not #{total} in all" if small + lost != total
  return "small dropped nothing, so the queue was never full" if lost == 0
  return "some handler got an event twice: #{plan.twice.to_map()}" if plan.twice.size > 0
  return "a handler got an event after its detach: #{plan.late.to_map()}" if plan.late.size > 0

  left = Telemetry.handlers()
  return "the handlers left are #{left}" if left != ["everything", "same", "small"]
  return "the hub does not route" if not Telemetry.enabled?(TICK)

  "ok"
end

def count_span(ids: ATS[String, Int], event: Telemetry.Event) -> Result[Void]
  _ = ids.add(event.metadata.get("span_id", ""), 1)
  ok()
end

def spans(worker: Int, count: Int) -> Result[Void]
  for i in 1..count
    _ = Telemetry.span("stress.span", {"worker": "#{worker}"}, -> { ok(i) })
  end

  ok()
end

def emit_all(worker: Int, count: Int) -> Result[Void]
  for i in 1..count
    Telemetry.execute("stress.cap", {"worker": worker, "seq": i})
  end

  ok()
end

# The events must be all there, and each task's events in the order it emitted them.
def in_order(found: List[Telemetry.Event], total: Int) -> String
  return "#{found.size} events, not #{total}" if found.size != total

  last: Map[Int, Int] = {}
  for event in found
    worker = event.ints.get("worker", 0)
    seq = event.ints.get("seq", 0)
    return "the events of worker #{worker} are out of order at #{seq}" if seq != last.get(worker, 0) + 1

    last = last.put(worker, seq)
  end

  "ok"
end

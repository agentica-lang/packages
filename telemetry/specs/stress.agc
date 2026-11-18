## Many tasks attach, detach and emit at the same time, on the hub of the driver. The run checks that:
## - a handler attached for the whole run gets exactly the events that were emitted, once each (after `flush`);
## - no handler gets an event twice;
## - of several attaches of one id at once, exactly one succeeds;
## - the hub is alive at the end and `handlers` lists what is left.

import Telemetry from "../telemetry"

## Runs the stress with `workers` tasks that emit `events` events each, and gives `ok` or what went wrong.
def run(workers: Int, events: Int) -> String
  plan = Plan(events: events, seen: ATS.new(), totals: ATS.new(), twice: ATS.new())
  everything = Telemetry.attach("everything", ["*"], recorder(plan, "everything"))
  return "everything was not attached" if not everything.ok?

  tasks = (1..workers).to_a
  attached = Task.map(tasks, workers, TASK_MS, ->(worker) { attach_same(plan, worker) })
  winners = attached.select(->(result) { result.ok? }).size
  played = Task.map(tasks, workers, TASK_MS, ->(worker) { play(plan, worker) })
  failed = played.select(->(result) { not result.ok? }).size
  flushed = Telemetry.flush(TASK_MS)
  verdict(plan, Counted(workers: workers, winners: winners, failed: failed, flushed: flushed.ok?))
end

private

TASK_MS = 60_000
TICK = "stress.tick"

struct Plan
  events: Int
  seen: ATS[String, Int]
  totals: ATS[String, Int]
  twice: ATS[String, Int]
end

struct Counted
  workers: Int
  winners: Int
  failed: Int
  flushed: Bool
end

# Counts what the handler `id` gets, and how many times it got the same event (`seq`).
def recorder(plan: Plan, id: String) -> Fn[Telemetry.Event, Result[Void]] = ->(event) { note(plan, id, event) }

def note(plan: Plan, id: String, event: Telemetry.Event) -> Result[Void]
  seq = event.ints.get("seq").unwrap_or(-1)
  _ = plan.totals.add(id, 1)
  if plan.seen.add("#{id}/#{seq}", 1) > 1
    _ = plan.twice.add(id, 1)
  end

  ok()
end

# Every task tries to take the id `same`; one gets it.
def attach_same(plan: Plan, _worker: Int) -> Result[Void] = Telemetry.attach("same", [TICK], recorder(plan, "same"))

# A task attaches a handler of its own, emits its events and detaches it.
def play(plan: Plan, worker: Int) -> Result[Void]
  id = "worker#{worker}"
  try Telemetry.attach(id, [TICK], recorder(plan, id))
  for i in 1..plan.events
    Telemetry.execute(TICK, {"seq": worker * plan.events + i}, {}, {"worker": "#{worker}"})
  end

  Telemetry.detach(id)
end

def verdict(plan: Plan, counted: Counted) -> String
  total = counted.workers * plan.events
  got = plan.totals.get("everything").unwrap_or(0)
  return "#{counted.winners} attaches of one id succeeded, not 1" if counted.winners != 1
  return "#{counted.failed} tasks failed to attach or detach" if counted.failed > 0
  return "flush ran out of time" if not counted.flushed
  return "everything got #{got} events, not #{total}" if got != total
  return "some handler got an event twice: #{plan.twice.to_map()}" if plan.twice.size > 0

  left = Telemetry.handlers()
  return "the handlers left are #{left}" if left != ["everything", "same"]
  return "the hub does not route" if not Telemetry.enabled?(TICK)

  "ok"
end

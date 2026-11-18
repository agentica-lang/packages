## Many tasks call `start` at once. Exactly one succeeds, the others get `telemetry.started`, and one hub runs: the
## tasks of the package that are running are the callers, their handlers and one hub. Each task attaches a handler as
## soon as its start returns, and every attach works.

import Telemetry from "../telemetry"

## Runs the starts with `starters` tasks, and gives `ok` or what went wrong.
def run(starters: Int) -> String
  held: Channel[Bool] = Channel.new(1)
  answers: Channel[String] = Channel.new(starters)
  before = Task.pending_count()
  tasks = (1..starters).to_a.map(->(n) { Task.spawn(&start_and_wait, Start(n: n, answers: answers, held: held)) })
  results = (1..starters).to_a.map(->(_n) { answers.recv(WAIT_MS).unwrap_or("no answer") })
  running = Task.pending_count() - before
  held.close
  for task in tasks
    Task.await(task)
  end

  verdict(results, running, starters)
end

private

WAIT_MS = 10_000

struct Start
  n: Int
  answers: Channel[String]
  held: Channel[Bool]
end

# The hub is a child of its starter, so a task that wins keeps it by staying until the check is done. Each
# task attaches
# a handler at once, which a start that returned before the hub was registered would not find.
def start_and_wait(start: Start) -> Void
  started = kind(Telemetry.start())
  attached = kind(Telemetry.attach("starter#{start.n}", ["start"], &quiet))
  _ = start.answers.send("#{started}/#{attached}", WAIT_MS)
  _ = start.held.recv(WAIT_MS)
  nil
end

def kind(result: Result[Void]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def quiet(_event: Telemetry.Event) -> Result[Void] = ok()

def verdict(results: List[String], running: Int, starters: Int) -> String
  winners = results.select(->(text) { text == "ok/ok" }).size
  others = results.select(->(text) { text == "telemetry.started/ok" }).size
  return "#{winners} starts succeeded, not 1: #{results}" if winners != 1
  return "#{others} starts gave telemetry.started, not #{starters - 1}: #{results}" if others != starters - 1
  if running != 2 * starters + 1
    return "#{running} tasks run, not #{starters} callers, #{starters} handlers and one hub"
  end

  "ok"
end

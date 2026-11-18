## Many tasks call `start` at once. Exactly one succeeds, the others get `telemetry.started`, and one hub runs: the
## tasks of the package that are running are those of the callers and one more.

import Telemetry from "../telemetry"

## Runs the starts with `starters` tasks, and gives `ok` or what went wrong.
def run(starters: Int) -> String
  held: Channel[Bool] = Channel.new(1)
  answers: Channel[String] = Channel.new(starters)
  before = Task.pending_count()
  tasks = (1..starters).to_a.map(->(_n) { Task.spawn(&start_and_wait, Start(answers: answers, held: held)) })
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
  answers: Channel[String]
  held: Channel[Bool]
end

# The hub is a child of its starter, so a task that wins keeps it by staying until the check is done.
def start_and_wait(start: Start) -> Void
  result = Telemetry.start()
  text = "ok"
  case result
    ok(_) -> nil
    error(e) -> text = e.kind
  end

  _ = start.answers.send(text, WAIT_MS)
  _ = start.held.recv(WAIT_MS)
  nil
end

def verdict(results: List[String], running: Int, starters: Int) -> String
  winners = results.select(->(text) { text == "ok" }).size
  others = results.select(->(text) { text == "telemetry.started" }).size
  return "#{winners} starts succeeded, not 1: #{results}" if winners != 1
  return "#{others} starts gave telemetry.started, not #{starters - 1}: #{results}" if others != starters - 1
  return "#{running} tasks run, not #{starters} and one hub" if running != starters + 1

  "ok"
end

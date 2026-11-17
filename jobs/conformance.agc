## The conformance suite: the cases that every backend must pass, run against a backend that the caller makes. A
## backend package has one scenario, "the backend passes every contract case", that calls `run_all` with its own
## `Maker` and fails with `failed(outcomes)`, so a backend that moves to a newer `jobs` tag runs the new cases with no
## change.
##
## The suite gives each case a fresh backend that follows a manual clock, so no case sleeps. A backend that cannot
## follow an injected clock (`Caps.has_clock` false) gets the real clock instead: its cases sleep, with a unit of time
## of one second, and a case only checks what holds a little before and a little after a time. Cases that start tasks
## run in the task that calls the suite, which makes the backend, so the backend stays up while the case runs.

import Cases from "src/cases"
import Jobs from "jobs"

## Makes a fresh, empty backend that reads time from the given clock (`Jobs.Clock.now`).
type Maker = Fn[Fn[Int], Result[Jobs.Backend]]

enum Status
  Passed
  Failed(String)
end

struct Outcome
  name: String
  status: Status
end

## The names of the cases, in the order `run_all` runs them.
def names() -> List[String] = Cases.all().map(->(item) { item.name })

## Runs one case by name. It gives `ok` when the case passes, and its error when it fails; a name that is
## not a case is `argument`.
def run(name: String, make: Maker) -> Result[Void]
  case Cases.all().find(->(item) { item.name == name })
    ok(item) -> report(Outcome(name: name, status: execute(item, make)))
    error(_) -> error("conformance: there is no case #{name}", kind: "argument")
  end
end

## Runs every case, one fresh backend each.
def run_all(make: Maker) -> List[Outcome]
  Cases.all().map(->(item) { Outcome(name: item.name, status: execute(item, make)) })
end

## The names of the cases that failed.
def failed(outcomes: List[Outcome]) -> List[String]
  outcomes.filter(->(outcome) { failed?(outcome) }).map(->(outcome) { outcome.name })
end

## The cases that failed, one line each, with what went wrong; empty when none did.
def failures(outcomes: List[Outcome]) -> String
  lines = outcomes.map(&line)
  lines.filter(->(text) { text != "" }).join("\n")
end

private

CASE_MS = 120_000
CLOSE_MS = 1_000
MANUAL_UNIT_MS = 1_000
REAL_UNIT_MS = 1_000

def failed?(outcome: Outcome) -> Bool
  case outcome.status
    Status.Failed(_) -> true
    Status.Passed -> false
  end
end

def line(outcome: Outcome) -> String
  case outcome.status
    Status.Failed(why) -> "#{outcome.name}: #{why}"
    Status.Passed -> ""
  end
end

def report(outcome: Outcome) -> Result[Void]
  case outcome.status
    Status.Failed(why) -> error("conformance: #{outcome.name}: #{why}", kind: "conformance.failed")
    Status.Passed -> ok()
  end
end

def execute(item: Cases.Case, make: Maker) -> Status
  clock = Jobs.manual_clock()
  case make.call(clock.now)
    ok(backend) -> run_on(item, backend, clock)
    error(e) -> Status.Failed("the backend did not start: #{e.message}")
  end
end

def run_on(item: Cases.Case, backend: Jobs.Backend, clock: Jobs.Clock) -> Status
  status = attempt(item, environment(backend, clock))
  Jobs.close(backend, CLOSE_MS)
  status
end

# The manual clock, or the real one for a backend that does not follow an injected clock.
def environment(backend: Jobs.Backend, clock: Jobs.Clock) -> Cases.Env
  return Cases.Env(backend: backend, clock: clock, exact: true, unit_ms: MANUAL_UNIT_MS) if backend.caps.has_clock

  real = Jobs.Clock(now: &Time.now_ms, advance: ->(ms) { Task.sleep(ms) })
  Cases.Env(backend: backend, clock: real, exact: false, unit_ms: REAL_UNIT_MS)
end

# The case runs in a task of its own, so that a crash or a hang in it is a failed case and not the end of the suite.
def attempt(item: Cases.Case, env: Cases.Env) -> Status
  task = Task.spawn do item.run.call(env) end
  case Task.await(task, CASE_MS)
    Await.Done(result) -> judged(result)
    Await.TimedOut ->
      Task.cancel(task)
      Status.Failed("the case did not end in #{CASE_MS} ms")
  end
end

def judged(result: Result[Void]) -> Status
  case result
    ok(_) -> Status.Passed
    error(e) -> Status.Failed(e.message)
  end
end

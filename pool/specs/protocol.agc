## The requests that the step program (`steps.agc`) sends to the driver (`driver.agc`), one JSON line each.
##
## The driver owns the pool and the jobs that use it: a step program cannot keep tasks between its steps, so each
## scenario starts a driver process and talks to it. The driver answers every request with one line: `ok`, or the
## reason the request or the expectation failed.

## The reply that means the request worked.
OK = "ok"

## What the body of a job does with its resource: `Holds` it for `ms`, `Probe` is the same but counts in a peak of its
## own, `Loops` takes one again and again for `ms`, `Crashes`, `Fails`, `Hangs` (never returns), `Gated` holds it until
## the jobs are released, and `Nests` does a checkout inside its body.
enum Kind
  Holds
  Probe
  Loops
  Crashes
  Fails
  Hangs
  Gated
  Nests
end

## A job that a step starts: `name` names it for the expectations, `kind` is what it does, `ms` is the time a `Holds` job
## keeps its resource or a `Loops` job runs, and `times` how many times a `Holds` job takes one in turn (0: once).
struct Job
  name: String
  kind: Kind
  ms: Int = 0
  times: Int = 0
end

## `callers` callers at once that each take a resource `times` times (0: once) and hold it for `hold_ms`.
struct Flood
  callers: Int
  hold_ms: Int = 0
  times: Int = 0
end

## `callers` callers one after the other, each cancelled as its body crashes, `crash_ms` in.
struct Race
  callers: Int
  crash_ms: Int
end

## A start that must fail: the start of its error is `text`.
struct Failing
  text: String
  table: List[List[String]]
end

## What a job `name` must have got: a result or the kind of its error that starts with `text`.
struct Expect
  name: String
  text: String
end

## A job that must fail with a pool timeout, or, with `or_ok`, may succeed too.
struct Timeout
  name: String
  or_ok: Bool = false
end

## How a count is compared with a value: exactly (`Is`), at most (`AtMost`), or at least once it is polled long
## enough (`Reaches`).
enum Match
  Is
  AtMost
  Reaches
end

## A counter (of the driver, or of the pool) that must match `value`, polled for up to `wait_ms`.
struct Count
  name: String
  value: Int
  match: Match
  wait_ms: Int = 0
end

## A request, one for each thing a step asks of the driver. `Start`, `StartOwned` (in a task that `EndStarter` ends) take
## the settings of the pool (a header, then a name and a value per row), and `StartFails` those of a pool that must
## not start. `CancelJob` takes the name of a job, `Sleep` the ms, `Close` the drain in ms, `Release` lets the gated
## jobs go, and `ExpectOrder` the names of the jobs in the order they finished, joined by commas. The `Expect` ones
## are the expectations.
enum Request
  Start(List[List[String]])
  StartOwned(List[List[String]])
  StartFails(Failing)
  EndStarter
  Job(Job)
  Flood(Flood)
  CancelJob(String)
  RaceCrash(Race)
  WaitJobs
  Sleep(Int)
  Release
  Close(Int)
  ExpectJob(Expect)
  ExpectTimeout(Timeout)
  ExpectKind(Expect)
  ExpectOrder(String)
  ExpectCount(Count)
  ExpectPoolCount(Count)
  ExpectOneTask
end

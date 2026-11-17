## `Jobs.drain`: the jobs of a queue run one at a time in the caller, for an app's tests.

import Settle from "settle"
import Types from "types"

## Runs the jobs of the queue until none is due (`Due.Ready`) or none is left (`Due.All`), or `max_runs` ran.
def drain(backend: Types.Backend, drain: Types.Drain, handle: Fn[Types.Job, Result[Void]]) -> Result[Types.Drained]
  try check(drain)
  backoff = drain.backoff.unwrap_or(&Settle.default_backoff)
  now = clock_of(drain)
  fetch = Types.Fetch(queue: drain.queue, max: 1, lease_ms: LEASE_MS)
  drained = Types.Drained(done: 0, retried: 0, dead: 0)
  runs = 0
  steps = 0
  while runs < drain.max_runs
    leases = try backend.fetch.call(fetch)
    if leases.empty?
      break if steps >= MAX_STEPS or not try waiting?(backend, drain)

      steps += 1
      next
    end

    held = leases[0]
    verdict = Settle.settle(now.call(), held.job, handle.call(held.job), backoff)
    try Settle.apply(backend, held, verdict)
    drained = tally(drained, verdict)
    runs += 1
  end

  ok(drained)
end

private

# A lease long enough for a handler that does not move the clock.
LEASE_MS = 300_000
# Moves the clock past the longest default backoff (1 h plus jitter).
STEP_MS = 7_200_000
# How many times a drain moves the clock while it waits for jobs that are not due.
MAX_STEPS = 10_000

def check(drain: Types.Drain) -> Result[Void]
  if drain.max_runs < 1
    return error("jobs error: max_runs must be at least 1, got #{drain.max_runs}", kind: "argument")
  end

  case drain.due
    Types.Due.All if drain.clock.none? ->
      error("jobs error: Due.All needs the clock that the backend follows", kind: "argument")
    _ -> ok()
  end
end

def clock_of(drain: Types.Drain) -> Fn[Int]
  case drain.clock
    some(clock) -> clock.now
    none -> &Time.now_ms
  end
end

# Whether jobs wait for a time: with `Due.All` the clock moves to the time of the next ones.
def waiting?(backend: Types.Backend, drain: Types.Drain) -> Result[Bool]
  counts = try backend.counts.call(drain.queue)
  return ok(false) if drain.due == Types.Due.Ready or counts.scheduled == 0

  case drain.clock
    some(clock) -> clock.advance.call(STEP_MS)
    none -> nil
  end

  ok(true)
end

def tally(drained: Types.Drained, verdict: Settle.Verdict) -> Types.Drained
  case verdict
    Settle.Verdict.Ack -> drained.with(done: drained.done + 1)
    Settle.Verdict.Back(how) -> tally_back(drained, how)
  end
end

def tally_back(drained: Types.Drained, how: Types.Nack) -> Types.Drained
  case how
    Types.Nack.Dead(_) -> drained.with(dead: drained.dead + 1)
    Types.Nack.Retry(_) -> drained.with(retried: drained.retried + 1)
    Types.Nack.Release -> drained.with(retried: drained.retried + 1)
  end
end

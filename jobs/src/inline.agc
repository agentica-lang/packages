## `Jobs.drain`: the jobs of a queue run one at a time in the caller, for an app's tests.

import Logger from "std/logger"
import Settle from "settle"
import Types from "types"

## Runs the jobs of the queue until none is due (`Due.Ready`) or none is left (`Due.All`), or `max_runs` ran.
def drain(backend: Types.Backend, options: Types.Drain, handle: Fn[Types.Job, Result[Void]]) -> Result[Types.Drained]
  try check(options)
  backoff = options.backoff.unwrap_or(&Settle.default_backoff)
  now = clock_of(options)
  fetch = Types.Fetch(queue: options.queue, max: 1, lease_ms: LEASE_MS)
  drained = Types.Drained(done: 0, retried: 0, dead: 0)
  runs = 0
  steps = 0
  while runs < options.max_runs
    leases = try backend.fetch.call(fetch)
    if leases.empty?
      break if steps >= MAX_STEPS or not try waiting?(backend, options)

      steps += 1
      next
    end

    held = leases[0]
    result = handle.call(held.job)
    verdict = Settle.settle(now.call(), held.job, result, backoff)
    try Settle.apply(backend, held, verdict)
    log_verdict(held.job, result, verdict)
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

def check(options: Types.Drain) -> Result[Void]
  if options.max_runs < 1
    return error("jobs error: max_runs must be at least 1, got #{options.max_runs}", kind: "argument")
  end

  case options.due
    Types.Due.All if options.clock.none? ->
      error("jobs error: Due.All needs the clock that the backend follows", kind: "argument")
    _ -> ok()
  end
end

def clock_of(options: Types.Drain) -> Fn[Int]
  case options.clock
    some(clock) -> clock.now
    none -> &Time.now_ms
  end
end

# Whether jobs wait for a time: with `Due.All` the clock moves to the time of the next ones.
def waiting?(backend: Types.Backend, options: Types.Drain) -> Result[Bool]
  counts = try backend.counts.call(options.queue)
  return ok(false) if options.due == Types.Due.Ready or counts.scheduled == 0

  case options.clock
    some(clock) -> clock.advance.call(STEP_MS)
    none -> nil
  end

  ok(true)
end

# A job that fails is a recovered problem while it will run again, and a failure that is given up when it is dead. The
# fields are ids and counts, never the payload or the text of the error.
def log_verdict(job: Types.Job, result: Result[Void], verdict: Settle.Verdict) -> Void
  fields = {"queue": job.queue, "id": job.id, "attempt": job.attempt.to_s}
  case verdict
    Settle.Verdict.Back(Types.Nack.Retry(_)) -> Logger.warning("job failed, it will run again", fields)
    Settle.Verdict.Back(Types.Nack.Dead(_)) -> Logger.err("job dead", fields.put("reason", reason_of(result)))
    _ -> nil
  end
end

# `discarded` when the handler gave the job up, and `attempts_exhausted` when it failed on its last attempt.
def reason_of(result: Result[Void]) -> String
  case result
    error(e) if e.is_a?("jobs.discard") -> "discarded"
    _ -> "attempts_exhausted"
  end
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

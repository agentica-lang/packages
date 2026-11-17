## What happens to a job after its handler ran: one function decides, so `Jobs.drain` and the pipeline treat a job
## the same way.

import Types from "types"

## `Ack` removes the job; `Back` gives it back to the backend as the `Nack` says.
enum Verdict
  Ack
  Back(Types.Nack)
end

## `ok` acks. `Jobs.discard` makes the job dead at once, and so does any error on the last attempt. Another error
## runs the job again after `backoff(attempt)` ms.
def settle(now: Int, job: Types.Job, result: Result[Void], backoff: Fn[Int, Int]) -> Verdict
  case result
    ok(_) -> Verdict.Ack
    error(e) if e.is_a?("jobs.discard") -> Verdict.Back(Types.Nack.Dead(e.message))
    error(e) if job.attempt >= job.max_attempts -> Verdict.Back(Types.Nack.Dead(e.message))
    error(_) -> Verdict.Back(Types.Nack.Retry(now + backoff.call(job.attempt)))
  end
end

## Sends the verdict to the backend.
def apply(backend: Types.Backend, lease: Types.Lease, verdict: Verdict) -> Result[Void]
  case verdict
    Verdict.Ack -> backend.ack.call(lease)
    Verdict.Back(how) -> backend.nack.call(lease, how)
  end
end

## 1 s doubled for each attempt, up to 1 h, plus up to 20% of jitter, so that jobs that failed together do not come
## back together.
def default_backoff(attempt: Int) -> Int
  base = 1_000 * 2.pow((attempt - 1).clamp(0, MAX_DOUBLINGS))
  base = base.clamp(0, MAX_BACKOFF_MS)
  base + Random.int(0, base / 5)
end

private

MAX_BACKOFF_MS = 3_600_000
# 1 s doubled 12 times is above MAX_BACKOFF_MS, and a larger exponent would only grow the number.
MAX_DOUBLINGS = 12

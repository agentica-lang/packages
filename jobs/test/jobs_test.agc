import Jobs from "../jobs"
import Settle from "../src/settle"

private

struct Mail
  to: String
  tries: Int
end

def job(attempt: Int, max_attempts: Int) -> Jobs.Job
  Jobs.Job(
    id: "1",
    queue: "q",
    payload: "x".bytes,
    attempt: attempt,
    max_attempts: max_attempts,
    run_at_ms: 0,
    inserted_at_ms: 0,
    unique_key: none,
    meta: {},
    last_error: none,
  )
end

def fixed(attempt: Int) -> Int = 100 * attempt

def verdict_of(result: Result[Void], attempt: Int, max_attempts: Int) -> Settle.Verdict
  Settle.settle(5_000, job(attempt, max_attempts), result, &fixed)
end

def main() -> Void
  Test.run([
    Test.test("a payload made by json reads back as the same value") do
      mail = Mail(to: "ana@example.com", tries: 2)
      new = Jobs.json("mail", mail)
      held = job(1, 5).with(payload: new.payload)
      try Test.eq(new.queue, "mail")
      return Test.eq(Jobs.decode(held, Mail.codec), ok(mail))
    end,
    Test.test("a payload that is not the type is an error, and not a crash") do
      held = job(1, 5).with(payload: "not json".bytes)
      return Test.eq(Jobs.decode(held, Mail.codec).ok?, false)
    end,
    Test.test("a handler that returns ok acks, and discard is dead on any attempt") do
      try Test.eq(verdict_of(ok(), 1, 5), Settle.Verdict.Ack)
      return Test.eq(verdict_of(Jobs.discard("no"), 1, 5), Settle.Verdict.Back(Jobs.Nack.Dead("no")))
    end,
    Test.test("another error retries after the backoff, and is dead on the last attempt") do
      try Test.eq(verdict_of(error("boom"), 2, 5), Settle.Verdict.Back(Jobs.Nack.Retry(5_200)))
      return Test.eq(verdict_of(error("boom"), 5, 5), Settle.Verdict.Back(Jobs.Nack.Dead("boom")))
    end,
    Test.test("the default backoff doubles from 1 s, stays below 1 h and 20% of jitter, and never shrinks") do
      try Test.eq(Settle.default_backoff(1) >= 1_000 and Settle.default_backoff(1) <= 1_200, true)
      try Test.eq(Settle.default_backoff(4) >= 8_000 and Settle.default_backoff(4) <= 9_600, true)
      return Test.eq(Settle.default_backoff(500) >= 3_600_000 and Settle.default_backoff(500) <= 4_320_000, true)
    end,
    Test.test("a manual clock moves only when told") do
      clock = Jobs.manual_clock()
      start = clock.now.call()
      try Test.eq(clock.now.call(), start)
      clock.advance.call(250)
      return Test.eq(clock.now.call(), start + 250)
    end,
  ])
end

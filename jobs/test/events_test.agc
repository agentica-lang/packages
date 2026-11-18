import Events from "../src/events"
import Jobs from "../jobs"
import Telemetry from "pkg/telemetry/telemetry"

private

# What the events cost the task that calls with no handler attached, in steps (System.Profile.steps), which are the
# same on every run. Measured: the facade takes 26 to 36 steps more than the backend call (88 to 102 steps); the span
# of a job with its metadata 51 more than its body, and the settle event 29.
FACADE_EXTRA_STEPS = 50

def steps_of[T](run: Fn[T]) -> Int
  before = System.Profile.steps()
  _ = run.call()
  System.Profile.steps() - before
end

def seed(backend: Jobs.Backend, count: Int) -> Void
  new = Jobs.NewJob(queue: "q", payload: "x".bytes)
  _ = Jobs.enqueue_all(backend, (1..count).map(->(_n) { new }))
end

def handled(_job: Jobs.Job) -> Result[Void] = ok()

def main() -> Void
  Test.run([
    Test.test("with no handler attached a call of the facade costs a few steps more than the backend's") do
      backend = Jobs.memory().unwrap!
      seed(backend, 20)
      new = Jobs.NewJob(queue: "q", payload: "x".bytes)
      leases = backend.fetch.call(Jobs.Fetch(queue: "q", max: 8)).unwrap!
      extras = [
        steps_of(-> { Jobs.enqueue(backend, new) }) - steps_of(-> { backend.enqueue.call([new]) }),
        steps_of(-> { Jobs.fetch(backend, Jobs.Fetch(queue: "q")) }) -
        steps_of(-> { backend.fetch.call(Jobs.Fetch(queue: "q")) }),
        steps_of(-> { Jobs.ack(backend, leases[0]) }) - steps_of(-> { backend.ack.call(leases[1]) }),
        steps_of(-> { Jobs.nack(backend, leases[2], Jobs.Nack.Release) }) -
        steps_of(-> { backend.nack.call(leases[3], Jobs.Nack.Release) }),
      ]

      Jobs.close(backend, 1_000)
      return Test.eq(extras.all?(->(extra) { extra > 0 and extra <= FACADE_EXTRA_STEPS }), true)
    end,
    Test.test("the span of a drained job and its settle event cost a bounded number of steps with no handler") do
      backend = Jobs.memory().unwrap!
      seed(backend, 1)
      job = backend.fetch.call(Jobs.Fetch(queue: "q")).unwrap![0].job
      span = steps_of(-> { Telemetry.span(Events.JOB, Events.job_meta(backend.name, job), -> { handled(job) }) })
      body = steps_of(-> { handled(job) })
      settled = steps_of(-> { Events.settled(backend, job, "ack") })
      Jobs.close(backend, 1_000)
      try Test.eq(span - body <= 2 * FACADE_EXTRA_STEPS, true)
      return Test.eq(settled <= FACADE_EXTRA_STEPS, true)
    end,
  ])
end

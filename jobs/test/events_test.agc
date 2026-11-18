import Events from "../src/events"
import Jobs from "../jobs"
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

private

# What the events cost the task that calls with no handler attached, in steps (System.Profile.steps), which are the
# same on every run. Measured: the facade takes 31 to 37 steps more than the backend call (88 to 102 steps); the span
# of a job with its metadata 38 more than its body, and the settle event 30. An event that is not guarded by
# `enabled?` takes some 50 steps more.
FACADE_EXTRA_STEPS = 55

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

def offered(queue: String) -> Jobs.NewJob = Jobs.NewJob(queue: queue, payload: "x".bytes)

def answered(duplicate: Bool) -> Jobs.Enqueued = Jobs.Enqueued(id: "1", duplicate: duplicate)

def line(event: Telemetry.Event) -> String
  "#{event.metadata.get("queue", "")} #{event.ints.get("count", -1)} #{event.ints.get("duplicate_count", -1)}"
end

# A batch in which the queues come mixed, and some jobs are duplicates, on a backend that answers as told.
def enqueue_mixed(backend: Jobs.Backend, capture: Testing.Capture) -> Result[List[String]]
  jobs = ["b", "a", "a", "c", "b", "c", "d"].map(&offered)
  said = [true, false, true, false, false, true, false].map(&answered)
  _ = Jobs.enqueue_all(backend.with(enqueue: ->(_jobs) { ok(said) }), jobs).unwrap!
  found = try Testing.events(capture)
  ok(found.map(&line))
end

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
      try Test.eq(span - body <= 55, true)
      return Test.eq(settled <= FACADE_EXTRA_STEPS, true)
    end,
    Test.test("a batch of mixed queues and duplicates is one event for each queue, in the order they first appear") do
      backend = Jobs.memory().unwrap!
      lines = Testing.session(["jobs.enqueue"], ->(capture) { enqueue_mixed(backend, capture) })
      Jobs.close(backend, 1_000)
      return Test.eq(lines, ok(["b 1 1", "a 1 1", "c 1 1", "d 1 0"]))
    end,
  ])
end

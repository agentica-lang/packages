## What `execute` costs the task that calls it, in steps (`System.Profile.steps`), which are the same on every run, so
## no test depends on the clock. The steps are the emitter's own: the handlers run in other tasks.

import Telemetry from "../telemetry"

private

# Measured: 19 steps with no handler, 85 for an event that no handler hears, 95 + 36 for each handler that hears it.
# The limits leave room for a small change, and fail for a cost that grows with the handlers that do not match, or
# faster than one cast for each that does.
NO_HANDLER_STEPS = 25
UNHEARD_STEPS = 100
BASE_STEPS = 110
PER_HANDLER_STEPS = 40
ENDED_MS = 2_000

def quiet(_event: Telemetry.Event) -> Result[Void] = ok()

def attach_many(count: Int, pattern: String) -> Result[Void]
  for i in 1..count
    try Telemetry.attach("#{pattern}#{i}", [pattern], &quiet)
  end

  ok()
end

# The steps of one `execute` of an event with measurements and metadata, as a library emits it.
def steps_of(name: String) -> Int
  before = System.Profile.steps()
  Telemetry.execute(name, {"duration_ns": 1_200}, {"ratio": 0.5}, {"queue": "mail"})
  System.Profile.steps() - before
end

def steps_with(handlers: Int, pattern: String) -> Result[Int]
  running = Task.pending_count()
  try Telemetry.start()
  try attach_many(handlers, pattern)
  used = steps_of("cost.stop")
  try Telemetry.stop()
  try ended(running)
  ok(used)
end

# `stop` returns when the hub has answered: its task and the handlers' are still ending, and a test must not return
# with tasks running.
def ended(running: Int) -> Result[Void]
  waited = 0
  while Task.pending_count() > running and waited < ENDED_MS
    Task.sleep(5)
    waited += 5
  end

  return error("the tasks of the hub did not end") if Task.pending_count() > running

  ok()
end

def main() -> Void
  Test.run([
    Test.test("with no handler an event takes a few steps, with or without a hub") do
      bare = steps_of("cost.stop")
      hub = try steps_with(0, "cost")
      try Test.assert(bare <= NO_HANDLER_STEPS, "no hub took #{bare} steps")
      Test.assert(hub <= NO_HANDLER_STEPS, "a hub with no handler took #{hub} steps")
    end,
    Test.test("an event that no handler hears takes the same steps whether 1 or 64 handlers are attached") do
      one = try steps_with(1, "other")
      many = try steps_with(64, "other")
      try Test.assert(one <= UNHEARD_STEPS, "an unheard event took #{one} steps")
      Test.eq(many, one)
    end,
    Test.test("an event that handlers hear costs a bounded amount for each of them") do
      for count in [1, 8, 64]
        used = try steps_with(count, "cost")
        limit = BASE_STEPS + PER_HANDLER_STEPS * count
        try Test.assert(used <= limit, "#{count} handlers took #{used} steps, and the limit is #{limit}")
      end

      ok()
    end,
  ])
end

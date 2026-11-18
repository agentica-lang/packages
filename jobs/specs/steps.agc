## The steps of the features. Most of them drive the memory backend through `driver.agc`, which holds the backend and
## the clock (see `protocol.agc`): a step cannot keep the backend's actor between steps. The steps of the conformance
## suite run it in the step itself, since a case makes its own backend and ends it.

import BDD from "std/bdd"
import Conformance from "../conformance"
import Jobs from "../jobs"
import Model from "model"
import {
  Add, Backoff, Batch, Clocking, Crowd, Extension, Mode, Park, Request, Run, Settings, Take, Unpark,
} from "protocol"

private

REPLY_MS = 60_000
LEASE_MS = 30_000
OUTCOMES = "outcomes"
REPLY = "reply"
HEADER = [["setting", "value"]]

def main() -> Void
  BDD.run([
    BDD.step("a memory backend on a manual clock") do |ctx, _args| ask(ctx, Request.Start(Settings())) end,
    BDD.step("a memory backend on a manual clock with:") do |ctx, _args|
      ask(ctx, Request.Start(settings_of(BDD.table(ctx))))
    end,
    BDD.step("a memory backend on the wall clock") do |ctx, _args|
      ask(ctx, Request.Start(Settings(clock: Clocking.Wall)))
    end,
    BDD.step("I enqueue {string} into {string}") do |ctx, args|
      ask(ctx, Request.Enqueue(Add(queue: args[1], text: args[0], table: HEADER)))
    end,
    BDD.step("I enqueue {string} into {string} with:") do |ctx, args|
      ask(ctx, Request.Enqueue(Add(queue: args[1], text: args[0], table: BDD.table(ctx))))
    end,
    BDD.step("I enqueue the jobs {string} into {string} in one batch") do |ctx, args|
      ask(ctx, Request.EnqueueAll(Batch(queue: args[1], text: args[0])))
    end,
    BDD.step("I enqueue the jobs {string} into {string} in one batch, with the unique keys {string}") do |ctx, args|
      ask(ctx, Request.EnqueueAll(Batch(queue: args[1], text: args[0], keys: args[2].split(","))))
    end,
    BDD.step("I fetch a job of {string} as {string}") do |ctx, args|
      ask(ctx, Request.Fetch(Take(queue: args[0], name: args[1], lease_ms: LEASE_MS)))
    end,
    BDD.step("I fetch a job of {string} as {string}, leased for {int} ms") do |ctx, args|
      ask(ctx, Request.Fetch(Take(queue: args[0], name: args[1], lease_ms: args[2].to_i!)))
    end,
    BDD.step("I fetch a job of {string} as {string}, at most {int} per group") do |ctx, args|
      ask(ctx, Request.Fetch(Take(queue: args[0], name: args[1], lease_ms: LEASE_MS, limit: args[2].to_i!)))
    end,
    BDD.step("I fetch {int} jobs of {string} as {string}") do |ctx, args|
      ask(ctx, Request.Fetch(Take(queue: args[1], name: args[2], lease_ms: LEASE_MS, max: args[0].to_i!)))
    end,
    BDD.step("I ack {string}") do |ctx, args| ask(ctx, Request.Ack(args[0])) end,
    BDD.step("I retry {string} in {int} ms") do |ctx, args|
      ask(ctx, Request.Retry(Backoff(name: args[0], ms: args[1].to_i!)))
    end,
    BDD.step("I retry {string} in {int} ms, with the error {string}") do |ctx, args|
      ask(ctx, Request.Retry(Backoff(name: args[0], ms: args[1].to_i!, why: args[2])))
    end,
    BDD.step("I release {string}") do |ctx, args| ask(ctx, Request.Release(args[0])) end,
    BDD.step("I kill {string}") do |ctx, args| ask(ctx, Request.Kill(args[0])) end,
    BDD.step("I extend {string} by {int} ms") do |ctx, args|
      ask(ctx, Request.Extend(Extension(name: args[0], ms: args[1].to_i!)))
    end,
    BDD.step("the clock moves {int} ms") do |ctx, args| ask(ctx, Request.Advance(args[0].to_i!)) end,
    BDD.step("I ask for the counts of {string}") do |ctx, args| ask(ctx, Request.Counts(args[0])) end,
    BDD.step("I close the backend") do |ctx, _args| ask(ctx, Request.Close(1_000)) end,
    BDD.step("a fetch of {string} starts to wait as {string}") do |ctx, args|
      ask(ctx, Request.Wait(Park(queue: args[0], name: args[1])))
    end,
    BDD.step("a fetch of {string} starts to wait as {string} for {int} ms") do |ctx, args|
      ask(ctx, Request.Wait(Park(queue: args[0], name: args[1], wait_ms: args[2].to_i!)))
    end,
    BDD.step("a fetch of {string} starts to wait as {string}, at most {int} per group") do |ctx, args|
      ask(ctx, Request.Wait(Park(queue: args[0], name: args[1], limit: args[2].to_i!)))
    end,
    BDD.step("the fetch {string} ends") do |ctx, args| ask(ctx, Request.WaitEnd(Unpark(name: args[0]))) end,
    BDD.step("the clock moves {int} ms at a time until the fetch {string} ends") do |ctx, args|
      ask(ctx, Request.WaitEnd(Unpark(name: args[1], step_ms: args[0].to_i!)))
    end,
    BDD.step("I drain {string}") do |ctx, args| ask(ctx, Request.Drain(Run(queue: args[0], mode: Mode.Ready))) end,
    BDD.step("I drain {string}, at most {int} jobs") do |ctx, args|
      ask(ctx, Request.Drain(Run(queue: args[0], mode: Mode.Ready, max_runs: args[1].to_i!)))
    end,
    BDD.step("I drain {string}, with the jobs that wait for a time, and no clock") do |ctx, args|
      ask(ctx, Request.Drain(Run(queue: args[0], mode: Mode.AllWithoutClock)))
    end,
    BDD.step("I drain {string}, with the jobs that wait for a time") do |ctx, args|
      ask(ctx, Request.Drain(Run(queue: args[0], mode: Mode.All)))
    end,
    BDD.step("{int} consumers work off {int} jobs in {int} groups with at most {int} per group") do |ctx, args|
      ask(ctx, stress_in_groups(args, 0))
    end,
    BDD.step(
      "{int} consumers that wait {int} ms work off {int} jobs in {int} groups with at most {int} per group",
    ) do |ctx, args| ask(ctx, stress_in_groups([args[0], args[2], args[3], args[4]], args[1].to_i!)) end,
    BDD.step("I watch the events") do |ctx, _args| ask(ctx, Request.Watch(["jobs"])) end,
    BDD.step("I watch the events of {string}") do |ctx, args| ask(ctx, Request.Watch(args[0].split(","))) end,
    BDD.step("the event names are {string}") do |ctx, args| expect_names(ctx, args[0]) end,
    BDD.step("I read the events") do |ctx, _args| ask(ctx, Request.Events) end,
    BDD.step("the events are:") do |ctx, _args| expect_events(ctx, BDD.table(ctx)) end,
    BDD.step("the drain logged") do |ctx, _args| ask(ctx, Request.Logs) end,
    BDD.step("{int} consumers work off {int} jobs of one queue while producers add them") do |ctx, args|
      ask(ctx, Request.Stress(Crowd(consumers: args[0].to_i!, jobs: args[1].to_i!)))
    end,
    BDD.step(
      "{int} consumers that wait {int} ms work off {int} jobs of one queue while producers add them",
    ) do |ctx, args|
      ask(ctx, Request.Stress(Crowd(consumers: args[0].to_i!, jobs: args[2].to_i!, wait_ms: args[1].to_i!)))
    end,
    BDD.step("the memory backend answers like the model on {int} random calls from seed {int}") do |ctx, args|
      agree_with_model(ctx, args[0].to_i!, args[1].to_i!)
    end,
    BDD.step("the reply is {string}") do |ctx, args| expect_reply(ctx, args[0]) end,
    BDD.step("the suite runs on the memory backend") do |ctx, _args| run_suite(ctx, &memory) end,
    BDD.step("the suite runs on a memory backend whose ack never fails") do |ctx, _args|
      run_suite(ctx, &lenient_acks)
    end,
    BDD.step("the suite runs on a memory backend that ignores the wait of a fetch") do |ctx, _args|
      run_suite(ctx, &ignores_wait)
    end,
    BDD.step("the suite runs on a memory backend that ignores max_per_group") do |ctx, _args|
      run_suite(ctx, &ignores_groups)
    end,
    BDD.step("the suite runs on a memory backend whose nack and extend work after close") do |ctx, _args|
      run_suite(ctx, &open_after_close)
    end,
    BDD.step("the case {string} passes on a memory backend that reads the real clock") do |ctx, args|
      real_clock_case(ctx, args[0])
    end,
    BDD.step("the suite has {int} cases") do |ctx, args| expect_cases(ctx, args[0].to_i!) end,
    BDD.step("no case failed") do |ctx, _args| expect_no_failure(ctx) end,
    BDD.step("the case {string} passed") do |ctx, args| expect_status(ctx, args[0], "passed") end,
    BDD.step("the case {string} failed") do |ctx, args| expect_status(ctx, args[0], "failed") end,
  ])
end

# The consumers, the jobs, the groups and the limit of a stress in groups.
def stress_in_groups(args: List[String], wait_ms: Int) -> Request
  Request.Stress(
    Crowd(
      consumers: args[0].to_i!,
      jobs: args[1].to_i!,
      groups: args[2].to_i!,
      limit: args[3].to_i!,
      wait_ms: wait_ms,
    ),
  )
end

def start(ctx: BDD.Context) -> BDD.Context
  return ctx if BDD.get(ctx, "driver").ok?

  BDD.set(BDD.given_program(ctx, "driver.agc"), "driver", JSON.from(true))
end

# Sends the request to the driver, started on the first one, and keeps its reply line for the `Then` steps.
def ask(ctx: BDD.Context, req: Request) -> BDD.Context
  running = start(ctx)
  asked = BDD.when_line(running, JSON.encode(req))
  BDD.set(asked, REPLY, JSON.from(BDD.read_line(asked, REPLY_MS).unwrap_or("no reply from the driver")))
end

def expect_reply(ctx: BDD.Context, want: String) -> BDD.Context
  reply = JSON.string(BDD.get(ctx, REPLY).unwrap!).unwrap_or("")
  BDD.assert(ctx, reply == want, "the reply is #{reply}, and should be #{want}")
end

# The events since the last read, one per row of the table (the header first), as the driver says them.
def expect_events(ctx: BDD.Context, table: List[List[String]]) -> BDD.Context
  read = ask(ctx, Request.Events)
  rows = table.drop(1).map(->(row) { row[0] })
  return expect_reply(read, "ok") if rows.empty?

  expect_reply(read, "ok #{rows.join("; ")}")
end

# The names of the events since the last read, in the order they came, as the driver says them.
def expect_names(ctx: BDD.Context, names: String) -> BDD.Context
  read = ask(ctx, Request.EventNames)
  return expect_reply(read, "ok") if names == ""

  expect_reply(read, "ok #{names}")
end

# The settings that a table gives (a header, then a name and a value per row); the others keep their default.
def settings_of(table: List[List[String]]) -> Settings
  settings = Settings()
  for row in table.drop(1)
    case row[0]
      "max_jobs" -> settings = settings.with(max_jobs: row[1].to_i.unwrap_or(settings.max_jobs))
      "max_dead" -> settings = settings.with(max_dead: row[1].to_i.unwrap_or(settings.max_dead))
      "fetch_timeout_ms" -> settings = settings.with(fetch_timeout_ms: some(row[1].to_i.unwrap_or(0)))
      _ -> nil
    end
  end

  settings
end

def memory(clock: Fn[Int]) -> Result[Jobs.Backend] = Jobs.memory(Jobs.MemoryOptions(clock: some(clock)))

def lenient_acks(clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try memory(clock)
  ok(backend.with(ack: ->(_lease) { ok() }))
end

# A fetch that never waits: it answers at once, as a backend that ignores `wait_ms` does.
def ignores_wait(clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try memory(clock)
  ok(backend.with(fetch: ->(fetch) { backend.fetch.call(fetch.with(wait_ms: 0)) }))
end

# A fetch with no limit per group, as a backend that ignores `max_per_group` does.
def ignores_groups(clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try memory(clock)
  ok(backend.with(fetch: ->(fetch) { backend.fetch.call(fetch.with(max_per_group: 0)) }))
end

# A backend that keeps nack and extend working after close, the two calls that a check of close may forget.
def open_after_close(clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try memory(clock)
  closed: ATS[String, Int] = ATS.new()
  ok(
    backend.with(
      nack: ->(lease, how) {
        return ok() if closed.has_key?("closed")

        backend.nack.call(lease, how)
      },
      extend: ->(lease, ms) {
        return ok(lease) if closed.has_key?("closed")

        backend.extend.call(lease, ms)
      },
      close: ->(ms) {
        closed.put("closed", 1)
        backend.close.call(ms)
      },
    ),
  )
end

# A backend that ignores the clock it is given and reads the wall clock, as a database does.
def real_clock(_clock: Fn[Int]) -> Result[Jobs.Backend]
  backend = try Jobs.memory()
  ok(backend.with(caps: Jobs.Caps(has_clock: false)))
end

def real_clock_case(ctx: BDD.Context, name: String) -> BDD.Context
  result = Conformance.run(name, &real_clock)
  BDD.assert(ctx, result.ok?, "the case #{name} on the real clock: #{result}")
end

# The outcomes are kept as lines: `passed` or `failed`, a tab, the name of the case.
def run_suite(ctx: BDD.Context, make: Conformance.Maker) -> BDD.Context
  lines = Conformance.run_all(make).map(->(outcome) { "#{status_word(outcome.status)}\t#{outcome.name}" })
  BDD.set(ctx, OUTCOMES, JSON.from(lines))
end

def status_word(status: Conformance.Status) -> String
  case status
    Conformance.Status.Passed -> "passed"
    Conformance.Status.Failed(_) -> "failed"
  end
end

def outcomes(ctx: BDD.Context) -> List[String]
  JSON.decode(BDD.get(ctx, OUTCOMES).unwrap!, List[String]).unwrap_or([])
end

def expect_cases(ctx: BDD.Context, count: Int) -> BDD.Context
  found = outcomes(ctx).size
  BDD.assert(ctx, found == count and Conformance.names().size == count, "the suite has #{found} cases, not #{count}")
end

def expect_no_failure(ctx: BDD.Context) -> BDD.Context
  failed = outcomes(ctx).filter(->(line) { line.start_with?("failed") })
  BDD.assert(ctx, failed.empty?, "cases failed: #{failed.join("; ")}")
end

def expect_status(ctx: BDD.Context, name: String, word: String) -> BDD.Context
  want = "#{word}\t#{name}"
  BDD.assert(ctx, outcomes(ctx).include?(want), "no case #{name} #{word}; the outcomes are #{outcomes(ctx)}")
end

# Sends the calls of a script to the driver, one after the other, and stops at the first reply that is not the model's.
def agree_with_model(ctx: BDD.Context, count: Int, seed: Int) -> BDD.Context
  calls = Model.script(seed, count)
  current = ctx
  position = 0
  for call in calls
    current = ask(current, call.req)
    reply = JSON.string(BDD.get(current, REPLY).unwrap!).unwrap_or("")
    current = BDD.assert(
      current,
      reply == call.reply,
      "call #{position} of the seed #{seed}, #{JSON.encode(call.req)}: the backend says #{reply}, " +
      "the model says #{call.reply}",
    )

    position += 1
  end

  BDD.assert(current, calls.size == count + 1, "the model wrote #{calls.size} calls")
end

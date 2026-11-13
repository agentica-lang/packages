## Checkouts per second of a pool of 4 trivial resources: 20,000 in a row from one task, then 1,000 tasks doing 20
## each, with the body in a task of its own (`lease_ms` 30000, the default) and in the caller (`lease_ms` 0). Run it
## from the package folder: `agentica bench/checkout.agc`, with a run count as the argument to repeat it (default 1).

import Pool from "../pool"

private

ROUNDS = 20_000
TASKS = 1_000
PER_TASK = 20
SIZE = 4
TASK_MS = 120_000
LEASES = [30_000, 0]

struct Load
  pool: Pool.Pool[ATS[String, Int], Int]
  failed: ATS[String, Int]
end

def main() -> Void
  args = System.args()
  runs = 1
  if not args.empty?
    runs = args[0].to_i!
  end

  for run in 1..runs
    for lease_ms in LEASES
      measure(run, lease_ms)
    end
  end
end

def measure(run: Int, lease_ms: Int) -> Void
  ids: ATS[String, Int] = ATS.new()
  spec = Pool.Spec(
    config: ids,
    init: &make,
    checkin: &back,
    terminate: &stop,
    ping: &alive,
    size: SIZE,
    lease_ms: lease_ms,
    checkout_ms: TASK_MS,
  )

  pool = Pool.start(spec).unwrap!
  t0 = Time.monotonic_ms()
  for _i in 1..ROUNDS
    _ = Pool.with(pool) do |n| ok(n) end
  end

  sequential = per_second(ROUNDS, Time.monotonic_ms() - t0)
  failed: ATS[String, Int] = ATS.new()
  load = Load(pool: pool, failed: failed)
  t1 = Time.monotonic_ms()
  _ = Task.map((1..TASKS).to_a, TASKS, TASK_MS) do |_t| work(load) end
  concurrent = per_second(TASKS * PER_TASK, Time.monotonic_ms() - t1)
  lost = failed.get("failed").unwrap_or(0)
  puts("run #{run} lease_ms #{lease_ms}: sequential #{sequential}/s, #{TASKS} tasks #{concurrent}/s, failed #{lost}")
  Pool.close(pool, 1_000)
end

def make(ids: ATS[String, Int]) -> Result[Int] = ok(ids.add("next", 1))

def back(_n: Int, _outcome: Pool.Outcome) -> Result[Void] = ok()

def stop(_n: Int) -> Void
  nil
end

def alive(_n: Int) -> Result[Void] = ok()

def work(load: Load) -> Result[Int]
  for _j in 1..PER_TASK
    got = Pool.with(load.pool) do |n| ok(n) end
    if not got.ok?
      load.failed.add("failed", 1)
    end
  end

  ok(0)
end

def per_second(count: Int, ms: Int) -> Int = (count * 1_000) / [ms, 1].max.unwrap!

## The program under test of the features: it holds one pool of fake resources and the jobs that use it, and runs the
## requests that `steps.agc` sends (`protocol.agc`), one JSON line in and one reply line out.
##
## A resource is a `Cell` with a number. The counters of the fake (`made`, `terminated`, `checkin_done`,
## `checkin_crashed`, `checkin_timed_out`, `checkouts`, `pings`, `active`, `peak`, and `alive` with its `alive_peak`)
## say what the pool did with its resources. `double_lease` counts the bodies that got a cell while another body still
## used it, and `kinds` holds the kind of each job's error.

import Pool from "../pool"
import Protocol from "protocol"
import {Request} from "protocol"

private

# Gap after a job starts, so that its task is in line for a resource before the next request starts another.
JOB_GAP_MS = 40
WAIT_JOBS_MS = 10_000
POLL_MS = 20
HANG_MS = 60_000
LOOP_NAP_MS = 5
SETTING_NAMES = [
  "size", "max_overflow", "overflow_idle_ms", "checkout_ms", "lease_ms", "max_age_ms", "idle_ms", "max_waiting",
  "lazy", "health_ms", "keep_dirty", "dirty_done", "bad_ping_id", "init_fails_from", "init_crashes_at", "slow_init_at",
  "slow_init_ms", "bad_checkout_id", "slow_ping_ms", "slow_terminate_ms", "slow_checkin_ms", "bad_checkin",
  "slow_checkout_ms", "checkout_fault",
]

# The resource of the pool.
struct Cell
  id: Int
  fake: Fake
end

# The config of the pool: where to count, and how the fake resource misbehaves.
struct Fake
  stats: ATS[String, Int]
  keep_dirty: Bool
  dirty_done: Bool
  bad_ping_id: Int
  init_fails_from: Int
  init_crashes_at: Int
  slow_init_at: Int
  slow_init_ms: Int
  bad_checkout_id: Int
  slow_ping_ms: Int
  slow_terminate_ms: Int
  slow_checkin_ms: Int
  bad_checkin: String
  slow_checkout_ms: Int
  checkout_fault: String
end

struct Driver
  stats: ATS[String, Int]
  kinds: ATS[String, String]
  finished: Channel[String]
  pool: Optional[Pool.Pool[Fake, Cell]]
  tasks: Map[String, Task[Result[Void]]]
  results: Map[String, String]
  order: List[String]
  starter: Optional[Task[Void]]
end

struct JobArgs
  pool: Pool.Pool[Fake, Cell]
  name: String
  kind: String
  ms: Int
  times: Int
  stats: ATS[String, Int]
  kinds: ATS[String, String]
  finished: Channel[String]
end

struct Handled
  driver: Driver
  reply: String
end

def main() -> Void
  stats: ATS[String, Int] = ATS.new()
  kinds: ATS[String, String] = ATS.new()
  finished: Channel[String] = Channel.new(5_000)
  driver = Driver(
    stats: stats,
    kinds: kinds,
    finished: finished,
    pool: none,
    tasks: {},
    results: {},
    order: [],
    starter: none,
  )

  line = IO.gets
  while line.ok?
    handled = handle(driver, line.unwrap_or(""))
    driver = handled.driver
    puts(handled.reply.replace("\n", "\\n"))
    IO.flush()
    line = IO.gets
  end
end

def handle(driver: Driver, line: String) -> Handled
  case JSON.decode(line, Request)
    error(message) -> Handled(driver: driver, reply: "bad request: #{message}")
    ok(req) -> act(driver, req)
  end
end

def act(driver: Driver, req: Request) -> Handled
  case req.op
    "start" -> start(driver, req)
    "start_fails" -> start_fails(driver, req)
    "start_owned" -> start_owned(driver, req)
    "end_starter" -> end_starter(driver)
    "job" -> start_job(driver, req)
    "flood" -> flood(driver, req)
    "cancel_job" -> cancel_job(driver, req.name)
    "wait_jobs" -> wait_jobs(driver)
    "sleep" -> slept(driver, req.number)
    "close" -> close(driver, req.number)
    "expect_job" -> expect_job(collect(driver), req)
    "expect_timeout" -> expect_timeout(collect(driver), req)
    "expect_kind" -> expect_kind(collect(driver), req)
    "expect_order" -> expect_order(collect(driver), req.text)
    "expect_count" -> expect_count(driver, req)
    "expect_one_task" -> expect_one_task(driver)
    "expect_pool_count" -> expect_pool_count(driver, req)
    _ -> Handled(driver: driver, reply: "unknown op #{req.op.inspect}")
  end
end

def reply(driver: Driver, message: String) -> Handled = Handled(driver: driver, reply: message)

# The Spec of a request: the defaults of `Pool.Spec`, then the settings of the table.
def spec_of(driver: Driver, table: List[List[String]]) -> Result[Pool.Spec[Fake, Cell]]
  settings: Map[String, String] = {}
  for row in table.drop(1)
    return error("unknown setting #{row[0].inspect}") if not SETTING_NAMES.include?(row[0])

    settings = settings.put(row[0], row[1])
  end

  fake = Fake(
    stats: driver.stats,
    keep_dirty: settings.get("keep_dirty", "false") == "true",
    dirty_done: settings.get("dirty_done", "false") == "true",
    bad_ping_id: try settings.get("bad_ping_id", "0").to_i,
    init_fails_from: try settings.get("init_fails_from", "0").to_i,
    init_crashes_at: try settings.get("init_crashes_at", "0").to_i,
    slow_init_at: try settings.get("slow_init_at", "0").to_i,
    slow_init_ms: try settings.get("slow_init_ms", "0").to_i,
    bad_checkout_id: try settings.get("bad_checkout_id", "0").to_i,
    slow_ping_ms: try settings.get("slow_ping_ms", "0").to_i,
    slow_terminate_ms: try settings.get("slow_terminate_ms", "0").to_i,
    slow_checkin_ms: try settings.get("slow_checkin_ms", "0").to_i,
    bad_checkin: settings.get("bad_checkin", "no"),
    slow_checkout_ms: try settings.get("slow_checkout_ms", "0").to_i,
    checkout_fault: settings.get("checkout_fault", "no"),
  )

  base = Pool.Spec(
    config: fake,
    init: &make,
    checkin: &check_in,
    terminate: &end_it,
    ping: &ping,
    checkout: some(&check_out),
  )

  ok(
    base.with(
      size: try settings.get("size", base.size.to_s).to_i,
      max_overflow: try settings.get("max_overflow", "0").to_i,
      overflow_idle_ms: try settings.get("overflow_idle_ms", base.overflow_idle_ms.to_s).to_i,
      checkout_ms: try settings.get("checkout_ms", base.checkout_ms.to_s).to_i,
      lease_ms: try settings.get("lease_ms", base.lease_ms.to_s).to_i,
      max_age_ms: try settings.get("max_age_ms", "0").to_i,
      idle_ms: try settings.get("idle_ms", "0").to_i,
      max_waiting: try settings.get("max_waiting", base.max_waiting.to_s).to_i,
      lazy: settings.get("lazy", "false") == "true",
      health_ms: try settings.get("health_ms", "0").to_i,
    ),
  )
end

def start(driver: Driver, req: Request) -> Handled
  case spec_of(driver, req.table)
    error(message) -> reply(driver, message.message)
    ok(spec) ->
      case Pool.start(spec)
        error(message) -> reply(driver, "the pool did not start: #{message}")
        ok(pool) -> reply(with_pool(driver, pool), Protocol.OK)
      end
  end
end

def with_pool(driver: Driver, pool: Pool.Pool[Fake, Cell]) -> Driver = driver.with(pool: some(pool))

# Starts the pool in a task that then waits, so that a step can end it, and the owner task of the pool with it.
def start_owned(driver: Driver, req: Request) -> Handled
  case spec_of(driver, req.table)
    error(message) -> reply(driver, message.message)
    ok(spec) ->
      started: Channel[Result[Pool.Pool[Fake, Cell]]] = Channel.new(1)
      starter = Task.spawn do
        _ = started.send(Pool.start(spec), 0)
        Task.sleep(HANG_MS)
      end

      case started.recv(WAIT_JOBS_MS)
        ok(ok(pool)) -> reply(with_pool(driver, pool).with(starter: some(starter)), Protocol.OK)
        ok(error(message)) -> reply(driver, "the pool did not start: #{message}")
        _ -> reply(driver, "the pool did not start within #{WAIT_JOBS_MS} ms")
      end
  end
end

def end_starter(driver: Driver) -> Handled
  case driver.starter
    none -> reply(driver, "no pool was started in a task")
    some(starter) ->
      Task.cancel(starter)
      reply(driver.with(starter: none), Protocol.OK)
  end
end

def start_fails(driver: Driver, req: Request) -> Handled
  case spec_of(driver, req.table)
    error(message) -> reply(driver, message.message)
    ok(spec) ->
      case Pool.start(spec)
        ok(_) -> reply(driver, "the pool started")
        error(message) -> reply(driver, expected_prefix(message.message, req.text))
      end
  end
end

# `ok` when the text starts with what was expected, else the text, which shows as the actual line of the step.
def expected_prefix(text: String, expected: String) -> String
  return Protocol.OK if text.start_with?(expected)

  text
end

def start_job(driver: Driver, req: Request) -> Handled
  case driver.pool
    none -> reply(driver, "no pool is started")
    some(pool) ->
      args = JobArgs(
        pool: pool,
        name: req.name,
        kind: req.kind,
        ms: req.number,
        times: [req.times, 1].max.unwrap!,
        stats: driver.stats,
        kinds: driver.kinds,
        finished: driver.finished,
      )

      run_fn: Fn[JobArgs, Result[Void]] = &run_job
      task = Task.spawn(run_fn, args)
      Task.sleep(JOB_GAP_MS)
      reply(driver.with(tasks: driver.tasks.put(req.name, task)), Protocol.OK)
  end
end

# Starts `number` callers at once that take a resource (`times` times each, at least once), hold it for `wait` ms and
# give it back; they have no name, and `flood_failed` counts the checkouts that got an error.
def flood(driver: Driver, req: Request) -> Handled
  case driver.pool
    none -> reply(driver, "no pool is started")
    some(pool) ->
      run_fn: Fn[JobArgs, Result[Void]] = &run_job
      tasks = driver.tasks
      for i in 1..req.number
        args = JobArgs(
          pool: pool,
          name: "",
          kind: "holds",
          ms: req.wait,
          times: [req.times, 1].max.unwrap!,
          stats: driver.stats,
          kinds: driver.kinds,
          finished: driver.finished,
        )

        tasks = tasks.put("flood #{i}", Task.spawn(run_fn, args))
      end

      Task.sleep(JOB_GAP_MS)
      reply(driver.with(tasks: tasks), Protocol.OK)
  end
end

def cancel_job(driver: Driver, name: String) -> Handled
  case driver.tasks.get(name)
    none -> reply(driver, "no job #{name.inspect}")
    some(task) ->
      Task.cancel(task)
      Task.sleep(JOB_GAP_MS)
      # A cancelled job has no result to wait for.
      reply(driver.with(tasks: driver.tasks.delete(name)), Protocol.OK)
  end
end

# A job whose body crashed in its own task (`lease_ms` 0) ends with that crash, which is its result.
def wait_jobs(driver: Driver) -> Handled
  for name in driver.tasks.keys
    case Task.await(driver.tasks.get(name).unwrap!, WAIT_JOBS_MS)
      Await.Done(ended) -> note_crash(driver, name, ended)
      Await.TimedOut -> return reply(driver, "a job did not end within #{WAIT_JOBS_MS} ms")
    end
  end

  reply(driver.with(tasks: {}), Protocol.OK)
end

def note_crash(driver: Driver, name: String, ended: Result[Void]) -> Void
  case ended
    ok(_) -> return
    error(e) ->
      driver.kinds.put(name, e.kind)
      _ = driver.finished.send("#{name} error #{e.message}", 1_000)
  end
end

def slept(driver: Driver, ms: Int) -> Handled
  Task.sleep(ms)
  reply(driver, Protocol.OK)
end

def close(driver: Driver, drain_ms: Int) -> Handled
  case driver.pool
    none -> reply(driver, "no pool is started")
    some(pool) ->
      Pool.close(pool, drain_ms)
      reply(driver, Protocol.OK)
  end
end

# Moves the jobs that ended from the channel to the results, in the order they ended.
def collect(driver: Driver) -> Driver
  current = driver
  while true
    case current.finished.recv(0)
      error(_) -> return current
      ok(line) ->
        words = line.split(" ")
        current = current.with(
          results: current.results.put(words[0], words.drop(1).join(" ")),
          order: current.order.push(words[0]),
        )
    end
  end

  current
end

def expect_job(driver: Driver, req: Request) -> Handled
  case driver.results.get(req.name)
    none -> reply(driver, "job #{req.name.inspect} has not ended")
    some(result) -> reply(driver, expected_prefix(result, req.text))
  end
end

# `kind` `or_ok` lets the job succeed too.
def expect_timeout(driver: Driver, req: Request) -> Handled
  case driver.results.get(req.name)
    none -> reply(driver, "job #{req.name.inspect} has not ended")
    some(result) ->
      message = result.split(" ").drop(1).join(" ")
      return reply(driver, Protocol.OK) if result.start_with?("error ") and Pool.timeout?(message)

      return reply(driver, Protocol.OK) if req.kind == "or_ok" and result.start_with?("ok ")

      reply(driver, "not a pool timeout: #{result}")
  end
end

def expect_kind(driver: Driver, req: Request) -> Handled
  case driver.kinds.get(req.name)
    error(_) -> reply(driver, "job #{req.name.inspect} has no error")
    ok(kind) -> reply(driver, expected_prefix(kind, req.text))
  end
end

def expect_order(driver: Driver, expected: String) -> Handled
  reply(driver, expected_prefix(driver.order.join(","), expected))
end

# Polls the counter every POLL_MS up to `wait` milliseconds: `is` wants the value exactly, `reaches` at least.
def expect_count(driver: Driver, req: Request) -> Handled
  deadline = Time.monotonic_ms() + req.wait
  value = driver.stats.get(req.name).unwrap_or(0)
  while not counted?(req, value) and Time.monotonic_ms() < deadline
    Task.sleep(POLL_MS)
    value = driver.stats.get(req.name).unwrap_or(0)
  end

  return reply(driver, Protocol.OK) if counted?(req, value)

  reply(driver, "the count #{req.name.inspect} is #{value}, not #{req.number}")
end

# A count that the pool keeps (`waiting`, `live`), polled like `expect_count`.
def expect_pool_count(driver: Driver, req: Request) -> Handled
  case driver.pool
    none -> reply(driver, "no pool is started")
    some(pool) ->
      deadline = Time.monotonic_ms() + req.wait
      value = pool.counts.get(req.name).unwrap_or(0)
      while not counted?(req, value) and Time.monotonic_ms() < deadline
        Task.sleep(POLL_MS)
        value = pool.counts.get(req.name).unwrap_or(0)
      end

      return reply(driver, Protocol.OK) if counted?(req, value)

      reply(driver, "the pool count #{req.name.inspect} is #{value}, not #{req.number}")
  end
end

# The `checkout` of the last resource lent and the body that got it ran in one task (with `lease_ms` 0 the
# caller's), so
# that no task is spawned for the check.
def expect_one_task(driver: Driver) -> Handled
  checkout = driver.stats.get("checkout_task").unwrap_or(0)
  body = driver.stats.get("body_task").unwrap_or(0)
  return reply(driver, "no checkout or no body ran") if checkout == 0 or body == 0

  return reply(driver, Protocol.OK) if checkout == body

  reply(driver, "the checkout ran in task #{checkout} and the body in task #{body}")
end

def counted?(req: Request, value: Int) -> Bool = value == req.number or (req.kind == "reaches" and value > req.number)

# The fake resource: a numbered cell that counts what the pool does with it.
def make(fake: Fake) -> Result[Cell]
  id = fake.stats.add("made", 1)
  if id == fake.slow_init_at
    Task.sleep(fake.slow_init_ms)
  end

  return ok(Cell(id: "not a number".to_i!, fake: fake)) if id == fake.init_crashes_at

  return error("init failed for resource #{id}") if fake.init_fails_from > 0 and id >= fake.init_fails_from

  alive = fake.stats.add("alive", 1)
  if alive > fake.stats.get("alive_peak").unwrap_or(0)
    fake.stats.put("alive_peak", alive)
  end

  ok(Cell(id: id, fake: fake))
end

# A cell is kept after a clean job (unless `dirty_done`); after a crash or a timeout only when the fake says so
# (`keep_dirty`). `slow_checkin_ms` makes each checkin take that long after it counted itself, and `bad_checkin`
# (`crashes`, `hangs`) makes it misbehave.
def check_in(cell: Cell, outcome: Pool.Outcome) -> Result[Void]
  case cell.fake.bad_checkin
    "crashes" -> return error("never #{"not a number".to_i!}")
    "hangs" -> Task.sleep(HANG_MS)
    _ -> nil
  end

  kept = checked_in(cell, outcome)
  if cell.fake.slow_checkin_ms > 0
    Task.sleep(cell.fake.slow_checkin_ms)
  end

  kept
end

def checked_in(cell: Cell, outcome: Pool.Outcome) -> Result[Void]
  stats = cell.fake.stats
  case outcome
    Pool.Outcome.Done ->
      stats.add("checkin_done", 1)
      return error("cell #{cell.id} is dirty") if cell.fake.dirty_done

      return ok()
    Pool.Outcome.Crashed -> stats.add("checkin_crashed", 1)
    Pool.Outcome.TimedOut -> stats.add("checkin_timed_out", 1)
  end

  return ok() if cell.fake.keep_dirty

  error("cell #{cell.id} is dirty")
end

# `bad_checkout_id` is the cell that `checkout` refuses, or, with `checkout_fault` (`crashes`, `hangs`), crashes on or
# hangs on. The task it runs in is counted in `checkout_task`, and the one of the body in `body_task`.
def check_out(cell: Cell) -> Result[Void]
  cell.fake.stats.add("checkouts", 1)
  cell.fake.stats.put("checkout_task", Task.current().id)
  if cell.id == cell.fake.bad_checkout_id
    case cell.fake.checkout_fault
      "crashes" -> return error("never #{"not a number".to_i!}")
      "hangs" -> Task.sleep(HANG_MS)
      _ -> nil
    end
  end

  if cell.fake.slow_checkout_ms > 0
    Task.sleep(cell.fake.slow_checkout_ms)
  end

  return error("cell #{cell.id} is refused") if cell.id == cell.fake.bad_checkout_id

  ok()
end

def end_it(cell: Cell) -> Void
  if cell.fake.slow_terminate_ms > 0
    Task.sleep(cell.fake.slow_terminate_ms)
  end

  cell.fake.stats.add("alive", -1)
  cell.fake.stats.add("terminated", 1)
end

def ping(cell: Cell) -> Result[Void]
  cell.fake.stats.add("pings", 1)
  if cell.fake.slow_ping_ms > 0
    Task.sleep(cell.fake.slow_ping_ms)
  end

  return error("cell #{cell.id} does not answer") if cell.id == cell.fake.bad_ping_id

  ok()
end

def run_job(args: JobArgs) -> Result[Void]
  return loop_job(args) if args.kind == "loops"

  for _i in 1..args.times
    result = Pool.with(args.pool) do |cell| use(args, cell) end
    if args.name.empty?
      if not result.ok?
        args.stats.add("flood_failed", 1)
      end
    else
      report(args, result)
    end
  end

  ok()
end

def report(args: JobArgs, result: Result[Int]) -> Void
  case result
    ok(id) -> _ = args.finished.send("#{args.name} ok #{id}", 1_000)
    error(e) ->
      args.kinds.put(args.name, e.kind)
      _ = args.finished.send("#{args.name} error #{e.message}", 1_000)
  end
end

# A caller that takes a resource again and again for `ms` milliseconds, as a busy server does. `loop_failed` counts
# the errors.
def loop_job(args: JobArgs) -> Result[Void]
  deadline = Time.monotonic_ms() + args.ms
  while Time.monotonic_ms() < deadline
    result = Pool.with(args.pool) do |cell| nap(cell) end
    if not result.ok?
      args.stats.add("loop_failed", 1)
    end
  end

  _ = args.finished.send("#{args.name} ok 0", 1_000)
  ok()
end

def nap(cell: Cell) -> Result[Int]
  Task.sleep(LOOP_NAP_MS)
  ok(cell.id)
end

# The body of a job: it holds the cell, crashes, fails or hangs. `peak` is the most cells in use at once; the `probe`
# jobs count in `probe_peak` instead, so that a check can ignore the jobs that came before them.
def use(args: JobArgs, cell: Cell) -> Result[Int]
  prefix = ""
  if args.kind == "probe"
    prefix = "probe_"
  end

  args.stats.add("body_ran", 1)
  args.stats.put("body_task", Task.current().id)
  if args.stats.add("cell #{cell.id}", 1) > 1
    args.stats.add("double_lease", 1)
  end

  active = args.stats.add("#{prefix}active", 1)
  if active > args.stats.get("#{prefix}peak").unwrap_or(0)
    args.stats.put("#{prefix}peak", active)
  end

  case args.kind
    "hangs" -> Task.sleep(HANG_MS)
    "crashes" ->
      args.stats.add("active", -1)
      args.stats.add("cell #{cell.id}", -1)
      return ok("not a number".to_i!)
    "fails" ->
      args.stats.add("active", -1)
      args.stats.add("cell #{cell.id}", -1)
      return error("the body failed")
    "nests" ->
      args.stats.add("active", -1)
      args.stats.add("cell #{cell.id}", -1)
      return nested(args)
    _ -> Task.sleep(args.ms)
  end

  args.stats.add("#{prefix}active", -1)
  args.stats.add("cell #{cell.id}", -1)
  ok(cell.id)
end

# A checkout inside the body, on the same pool: with every resource taken it waits its own `checkout_ms` and times out,
# which the body reports as -1.
def nested(args: JobArgs) -> Result[Int]
  inner = Pool.with(args.pool) do |cell| ok(cell.id) end
  case inner
    ok(id) -> ok(id)
    error(e) if e.is_a?("pool.timeout") -> ok(-1)
    error(e) -> error(e)
  end
end

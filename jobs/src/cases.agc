## The cases of the conformance suite (`conformance.agc` runs them). Each takes a fresh, empty backend on a clock that
## it controls, and gives `ok` or the error that says what the backend did wrong.

import Jobs from "../jobs"

## What a case runs on: a backend that follows `clock`.
struct Env
  backend: Jobs.Backend
  clock: Jobs.Clock
end

## A case, and the capabilities of a backend that it needs: without one, the case is skipped.
struct Case
  name: String
  needs_clock: Bool
  needs_unique_keys: Bool
  needs_extend: Bool
  run: Fn[Env, Result[Void]]
end

## Every case, in the order the suite runs them.
def all() -> List[Case]
  [
    pure("enqueue then fetch gives the job, byte for byte, with attempt 1", &roundtrip),
    pure("a fetch of an empty queue gives no jobs", &empty_queue),
    pure("queues do not see each other's jobs", &queues_apart),
    pure("a fetch that waits gets a job that is enqueued meanwhile", &waiting_fetch),
    timed("a fetch that waits gives no jobs when its time is up", &waiting_fetch_times_out),
    timed("a fetch that waits for a scheduled job gets it when it is due", &waiting_fetch_scheduled),
    timed("a leased job is not fetched again, and comes back when its lease expires", &lease_expires),
    timed("a late ack, nack or extend of an older delivery changes nothing", &stale_token),
    pure("ack removes the job, and a second ack fails", &ack_once),
    timed("a retry hides the job until its time", &retry_waits),
    pure("a release gives the job back at once, without counting the attempt", &release_keeps_attempt),
    timed("a dead job is never delivered again, and is counted", &dead_for_good),
    timed("the expiry of the last attempt makes the job dead", &last_attempt_expires),
    timed("a retry on the last attempt makes the job dead", &last_attempt_retries),
    extending("extend moves the end of the lease", &extend_moves),
    timed("a job is not delivered before its time", &not_early),
    unique("a unique key gives a duplicate until the job is acked or dead", &unique_key),
    pure("enqueue_all adds every job, or none", &all_or_nothing),
    pure("eight tasks fetch 200 jobs at once and each job is delivered once", &competing_fetchers),
    pure("after close, calls fail with jobs.closed", &closed_calls),
  ]
end

private

QUEUE = "conformance"
OTHER = "other"
LEASE_MS = 1_000
# Long enough that no lease of the fetchers runs out while they work.
LONG_LEASE_MS = 600_000
FETCHERS = 8
FETCHED_JOBS = 200
AWAIT_MS = 30_000
ADVANCES = 600
ADVANCE_MS = 50

def pure(name: String, run: Fn[Env, Result[Void]]) -> Case
  Case(name: name, needs_clock: false, needs_unique_keys: false, needs_extend: false, run: run)
end

def timed(name: String, run: Fn[Env, Result[Void]]) -> Case
  Case(name: name, needs_clock: true, needs_unique_keys: false, needs_extend: false, run: run)
end

def unique(name: String, run: Fn[Env, Result[Void]]) -> Case
  Case(name: name, needs_clock: false, needs_unique_keys: true, needs_extend: false, run: run)
end

def extending(name: String, run: Fn[Env, Result[Void]]) -> Case
  Case(name: name, needs_clock: true, needs_unique_keys: false, needs_extend: true, run: run)
end

def expect(condition: Bool, text: String) -> Result[Void]
  return error("conformance: #{text}", kind: "conformance.failed") if not condition

  ok()
end

def expect_kind[T](result: Result[T], kind: String, what: String) -> Result[Void]
  case result
    ok(_) -> error("conformance: #{what} succeeded, and should fail with #{kind}", kind: "conformance.failed")
    error(e) -> expect(e.is_a?(kind), "#{what} failed with #{e.kind}, and should fail with #{kind}")
  end
end

def job(queue: String, text: String) -> Jobs.NewJob = Jobs.NewJob(queue: queue, payload: text.bytes)

def add(env: Env, new: Jobs.NewJob) -> Result[Jobs.Enqueued] = Jobs.enqueue(env.backend, new)

def lease_one(env: Env, queue: String, lease_ms: Int) -> Result[Jobs.Lease]
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: queue, lease_ms: lease_ms))
  return error("conformance: a fetch of #{queue} gave no job", kind: "conformance.failed") if leases.empty?

  ok(leases[0])
end

def fetch_none(env: Env, queue: String) -> Result[Void]
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: queue))
  expect(leases.empty?, "a fetch of #{queue} gave #{leases.size} jobs, and should give none")
end

def expect_counts(env: Env, queue: String, ready: Int, scheduled: Int, leased: Int, dead: Int) -> Result[Void]
  counts = try Jobs.counts(env.backend, queue)
  want = Jobs.Counts(ready: ready, scheduled: scheduled, leased: leased, dead: dead)
  expect(counts == want, "the counts are #{counts}, and should be #{want}")
end

def advance(env: Env, ms: Int) -> Void
  env.clock.advance.call(ms)
end

def roundtrip(env: Env) -> Result[Void]
  payload = try Bytes.from_list([0, 255, 128, 10, 13, 65])
  new = Jobs.NewJob(queue: QUEUE, payload: payload, max_attempts: 3, meta: {"trace": "t-1"})
  second = job(QUEUE, "second")
  added = try Jobs.enqueue_all(env.backend, [new, second])
  try expect(added.size == 2, "enqueue_all of 2 jobs gave #{added.size} answers")
  try expect(added[0].id != added[1].id, "two jobs got the id #{added[0].id}")
  try expect(not added[0].duplicate, "a new job was a duplicate")
  now = env.clock.now.call()
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE, max: 2, lease_ms: LEASE_MS))
  try expect(leases.size == 2, "a fetch of 2 jobs gave #{leases.size}")
  held = leases[0]
  try expect(held.job.id == added[0].id, "the first job has the id #{held.job.id}, not #{added[0].id}")
  try expect(held.job.payload == payload, "the payload changed")
  try expect(held.job.attempt == 1, "the attempt is #{held.job.attempt}, and should be 1")
  try expect(held.job.queue == QUEUE and held.job.max_attempts == 3, "the queue or the max_attempts changed")
  try expect(held.job.meta == {"trace": "t-1"}, "the meta changed: #{held.job.meta}")
  try expect(held.job.last_error.none?, "a new job has the last_error #{held.job.last_error}")
  try expect(held.token != leases[1].token, "two leases share the token #{held.token}")
  if env.clock.now.call() == now
    try expect(held.expires_at_ms == now + LEASE_MS, "the lease ends at #{held.expires_at_ms}, not #{now + LEASE_MS}")
    return expect(held.job.inserted_at_ms == now, "inserted_at_ms is #{held.job.inserted_at_ms}, not #{now}")
  end

  ok()
end

def empty_queue(env: Env) -> Result[Void] = fetch_none(env, QUEUE)

def queues_apart(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  try fetch_none(env, OTHER)
  held = try lease_one(env, QUEUE, LEASE_MS)
  expect(held.job.queue == QUEUE, "the job is of the queue #{held.job.queue}")
end

def waiting_fetch(env: Env) -> Result[Void]
  waiting = Task.spawn do Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: AWAIT_MS)) end
  _ = try add(env, job(QUEUE, "late"))
  case Task.await(waiting, AWAIT_MS)
    Await.Done(answer) -> got_one(answer)
    Await.TimedOut -> error("conformance: a fetch that waits did not end", kind: "conformance.failed")
  end
end

def got_one(answer: Result[List[Jobs.Lease]]) -> Result[Void]
  leases = try answer
  expect(leases.size == 1, "the fetch that waited gave #{leases.size} jobs, and should give 1")
end

# Moves the clock until the task ends, so that the test does not depend on when the fetch started to wait.
def advance_until[T](env: Env, task: Task[T], ms: Int) -> Result[T]
  attempts = 0
  while attempts < ADVANCES
    advance(env, ms)
    case Task.await(task, ADVANCE_MS)
      Await.Done(value) -> return ok(value)
      Await.TimedOut -> attempts += 1
    end
  end

  error("conformance: a fetch that waits did not end when the clock moved", kind: "conformance.failed")
end

def waiting_fetch_times_out(env: Env) -> Result[Void]
  waiting = Task.spawn do Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: 5_000)) end
  leases = try try advance_until(env, waiting, 5_000)
  expect(leases.empty?, "a fetch that waited for nothing gave #{leases.size} jobs")
end

def waiting_fetch_scheduled(env: Env) -> Result[Void]
  at_ms = env.clock.now.call() + 10_000
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "later".bytes, run_at_ms: at_ms))
  waiting = Task.spawn do Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE, lease_ms: LEASE_MS, wait_ms: 3_600_000)) end
  answer = try advance_until(env, waiting, 10_000)
  leases = try answer
  try expect(leases.size == 1, "the fetch that waited for a scheduled job gave #{leases.size} jobs, and should give 1")
  expect(leases[0].job.run_at_ms == at_ms, "the job runs at #{leases[0].job.run_at_ms}, not #{at_ms}")
end

def lease_expires(env: Env) -> Result[Void]
  added = try add(env, job(QUEUE, "a"))
  first = try lease_one(env, QUEUE, LEASE_MS)
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, 0, 0, 1, 0)
  advance(env, LEASE_MS + 1)
  second = try lease_one(env, QUEUE, LEASE_MS)
  try expect(second.job.id == added.id, "the job came back with the id #{second.job.id}")
  try expect(second.job.attempt == 2, "the attempt is #{second.job.attempt} after an expiry, and should be 2")
  try expect(second.token != first.token, "a new delivery has the token of the old one")
  try expect_kind(Jobs.ack(env.backend, first), "jobs.lease_lost", "an ack with the token of the first delivery")
  Jobs.ack(env.backend, second)
end

def stale_token(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  first = try lease_one(env, QUEUE, LEASE_MS)
  advance(env, LEASE_MS + 1)
  second = try lease_one(env, QUEUE, LEASE_MS)
  try expect_kind(
    Jobs.nack(env.backend, first, Jobs.Nack.Dead("late")),
    "jobs.lease_lost",
    "a nack of an old delivery",
  )

  try expect_kind(Jobs.extend(env.backend, first, 5_000), "jobs.lease_lost", "an extend of an old delivery")
  try expect_counts(env, QUEUE, 0, 0, 1, 0)
  Jobs.ack(env.backend, second)
end

def ack_once(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.ack(env.backend, held)
  try expect_counts(env, QUEUE, 0, 0, 0, 0)
  expect_kind(Jobs.ack(env.backend, held), "jobs.lease_lost", "a second ack")
end

def retry_waits(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.nack(env.backend, held, Jobs.Nack.Retry(env.clock.now.call() + 5_000))
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, 0, 1, 0, 0)
  advance(env, 4_999)
  try fetch_none(env, QUEUE)
  advance(env, 1)
  again = try lease_one(env, QUEUE, LEASE_MS)
  expect(again.job.attempt == 2, "the attempt is #{again.job.attempt} after a retry, and should be 2")
end

def release_keeps_attempt(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.nack(env.backend, held, Jobs.Nack.Release)
  again = try lease_one(env, QUEUE, LEASE_MS)
  expect(again.job.attempt == 1, "the attempt is #{again.job.attempt} after a release, and should be 1")
end

def dead_for_good(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.nack(env.backend, held, Jobs.Nack.Dead("bad input"))
  try expect_counts(env, QUEUE, 0, 0, 0, 1)
  advance(env, 86_400_000)
  fetch_none(env, QUEUE)
end

def last_attempt_expires(env: Env) -> Result[Void]
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, max_attempts: 2))
  _ = try lease_one(env, QUEUE, LEASE_MS)
  advance(env, LEASE_MS + 1)
  second = try lease_one(env, QUEUE, LEASE_MS)
  try expect(second.job.attempt == 2, "the second delivery has the attempt #{second.job.attempt}")
  advance(env, LEASE_MS + 1)
  try fetch_none(env, QUEUE)
  expect_counts(env, QUEUE, 0, 0, 0, 1)
end

def last_attempt_retries(env: Env) -> Result[Void]
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, max_attempts: 1))
  held = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.nack(env.backend, held, Jobs.Nack.Retry(env.clock.now.call()))
  try fetch_none(env, QUEUE)
  expect_counts(env, QUEUE, 0, 0, 0, 1)
end

def extend_moves(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  now = env.clock.now.call()
  longer = try Jobs.extend(env.backend, held, 5_000)
  try expect(longer.expires_at_ms == now + 5_000, "the lease ends at #{longer.expires_at_ms}, not #{now + 5_000}")
  try expect(longer.token == held.token, "an extend changed the token")
  advance(env, 4_000)
  try fetch_none(env, QUEUE)
  try Jobs.ack(env.backend, longer)
  expect_counts(env, QUEUE, 0, 0, 0, 0)
end

def not_early(env: Env) -> Result[Void]
  at_ms = env.clock.now.call() + 10_000
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, run_at_ms: at_ms))
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, 0, 1, 0, 0)
  advance(env, 9_999)
  try fetch_none(env, QUEUE)
  advance(env, 1)
  try expect_counts(env, QUEUE, 1, 0, 0, 0)
  _ = try lease_one(env, QUEUE, LEASE_MS)
  ok()
end

def unique_key(env: Env) -> Result[Void]
  keyed = Jobs.NewJob(queue: QUEUE, payload: "a".bytes, unique_key: some("k"))
  first = try add(env, keyed)
  second = try add(env, keyed)
  try expect(
    second.duplicate and second.id == first.id,
    "a second job of the key is #{second}, not a duplicate of #{first}",
  )

  elsewhere = try add(env, Jobs.NewJob(queue: OTHER, payload: "a".bytes, unique_key: some("k")))
  try expect(not elsewhere.duplicate, "the same key in another queue was a duplicate")
  held = try lease_one(env, QUEUE, LEASE_MS)
  third = try add(env, keyed)
  try expect(third.duplicate, "a leased job did not hold its key")
  try Jobs.ack(env.backend, held)
  fourth = try add(env, keyed)
  try expect(not fourth.duplicate, "the key is not free after the ack")
  dying = try lease_one(env, QUEUE, LEASE_MS)
  try Jobs.nack(env.backend, dying, Jobs.Nack.Dead("no"))
  fifth = try add(env, keyed)
  expect(not fifth.duplicate, "the key is not free after the job is dead")
end

def all_or_nothing(env: Env) -> Result[Void]
  bad = Jobs.NewJob(queue: QUEUE, payload: "bad".bytes, max_attempts: 0)
  failed = Jobs.enqueue_all(env.backend, [job(QUEUE, "a"), bad, job(QUEUE, "b")])
  try expect_kind(failed, "argument", "an enqueue_all with a job of 0 attempts")
  try expect_counts(env, QUEUE, 0, 0, 0, 0)
  added = try Jobs.enqueue_all(env.backend, [job(QUEUE, "a"), job(QUEUE, "b")])
  try expect(added.size == 2, "enqueue_all of 2 jobs gave #{added.size} answers")
  expect_counts(env, QUEUE, 2, 0, 0, 0)
end

def competing_fetchers(env: Env) -> Result[Void]
  batch = (0...FETCHED_JOBS).map(->(n) { job(QUEUE, "job #{n}") })
  _ = try Jobs.enqueue_all(env.backend, batch)
  tasks = (0...FETCHERS).map(->(_n) { Task.spawn do take_all(env.backend) end })
  seen: Map[String, Int] = {}
  for task in tasks
    ids = try Task.await(task)
    for id in ids
      seen = seen.put(id, seen.get(id, 0) + 1)
    end
  end

  try expect(seen.size == FETCHED_JOBS, "the fetchers got #{seen.size} different jobs, and should get #{FETCHED_JOBS}")
  repeated = seen.values.filter(->(times) { times > 1 }).size
  expect(repeated == 0, "#{repeated} jobs were delivered more than once while their leases were live")
end

# Fetches one job at a time until the queue gives none, and gives their ids.
def take_all(backend: Jobs.Backend) -> Result[List[String]]
  ids: List[String] = []
  leases = try Jobs.fetch(backend, Jobs.Fetch(queue: QUEUE, lease_ms: LONG_LEASE_MS))
  while not leases.empty?
    ids = ids.push(leases[0].job.id)
    leases = try Jobs.fetch(backend, Jobs.Fetch(queue: QUEUE, lease_ms: LONG_LEASE_MS))
  end

  ok(ids)
end

def closed_calls(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE, LEASE_MS)
  Jobs.close(env.backend, 1_000)
  try expect_kind(Jobs.enqueue(env.backend, job(QUEUE, "b")), "jobs.closed", "an enqueue after close")
  try expect_kind(Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE)), "jobs.closed", "a fetch after close")
  try expect_kind(Jobs.ack(env.backend, held), "jobs.closed", "an ack after close")
  expect_kind(Jobs.counts(env.backend, QUEUE), "jobs.closed", "counts after close")
end

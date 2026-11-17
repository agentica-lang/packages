## The cases of the conformance suite (`conformance.agc` runs them). Each takes a fresh, empty backend, and gives `ok`
## or the error that says what the backend did wrong.
##
## A case moves time with `Env.clock`. For a backend that follows the manual clock (`exact`), a case moves it to the
## millisecond; for one that reads the real clock, `advance` sleeps, the unit of time is short but not tiny, and a case
## only checks what holds a little before and a little after a time.

import Jobs from "../jobs"

## What a case runs on: a backend, the clock it follows, and the unit of time (the lease of a job) in milliseconds.
struct Env
  backend: Jobs.Backend
  clock: Jobs.Clock
  exact: Bool
  unit_ms: Int
end

## A case: its name, and what it runs.
struct Case
  name: String
  run: Fn[Env, Result[Void]]
end

## Every case, in the order the suite runs them.
def all() -> List[Case]
  [
    Case(name: "enqueue then fetch gives the job, byte for byte, with attempt 1", run: &roundtrip),
    Case(name: "a fetch of an empty queue gives no jobs", run: &empty_queue),
    Case(name: "queues do not see each other's jobs", run: &queues_apart),
    Case(name: "a fetch that waits gets a job that is enqueued meanwhile", run: &waiting_fetch),
    Case(name: "a fetch that waits gives no jobs when its time is up", run: &waiting_fetch_times_out),
    Case(name: "a fetch that waits for a scheduled job gets it when it is due", run: &waiting_fetch_scheduled),
    Case(name: "a leased job is not fetched again, and comes back when its lease expires", run: &lease_expires),
    Case(name: "a late ack, nack or extend of an older delivery changes nothing", run: &stale_token),
    Case(
      name: "an ack, nack or extend after the lease ran out fails, before any other fetch",
      run: &lease_lost_after_expiry,
    ),
    Case(name: "ack removes the job, and a second ack fails", run: &ack_once),
    Case(name: "a retry hides the job until its time", run: &retry_waits),
    Case(name: "a release gives the job back at once, without counting the attempt", run: &release_keeps_attempt),
    Case(
      name: "the error of a retry is the last_error of the next delivery, and a retry without one keeps it",
      run: &last_error,
    ),
    Case(name: "a dead job is never delivered again, and is counted", run: &dead_for_good),
    Case(name: "the expiry of the last attempt makes the job dead", run: &last_attempt_expires),
    Case(name: "a retry on the last attempt makes the job dead", run: &last_attempt_retries),
    Case(name: "a lease is over at exactly its end, and not a millisecond before", run: &lease_end),
    Case(name: "extend moves the end of the lease, and the job comes back at the new end", run: &extend_moves),
    Case(name: "a job is not delivered before its time", run: &not_early),
    Case(name: "a unique key gives a duplicate until the job is acked or dead", run: &unique_key),
    Case(name: "a unique key stays held through a retry, a release and an expired lease", run: &unique_key_held),
    Case(
      name: "a unique key is free when the job dies on its last attempt, by expiry or by a retry",
      run: &unique_key_dies,
    ),
    Case(name: "two jobs of one batch with the same key are one job", run: &same_key_in_batch),
    Case(name: "enqueue_all adds every job, or none", run: &all_or_nothing),
    Case(name: "eight tasks fetch 200 jobs at once and each job is delivered once", run: &competing_fetchers),
    Case(name: "after close, calls fail with jobs.closed, and a second close does nothing", run: &closed_calls),
    Case(name: "a fetch that waits when the backend is closed ends with jobs.closed", run: &closed_while_waiting),
    Case(name: "a job keeps its group, and a bad group or limit is refused", run: &group_values),
    Case(name: "a full group is skipped while the jobs of other groups are served", run: &full_group_skipped),
    Case(name: "a group is counted in its own queue", run: &groups_per_queue),
    Case(name: "max_per_group 0 is no limit, and a job with no group is never limited", run: &no_limit),
    Case(name: "an ack frees the place of a group", run: &group_freed_by_ack),
    Case(name: "a retry frees the place of a group", run: &group_freed_by_retry),
    Case(name: "a release frees the place of a group", run: &group_freed_by_release),
    Case(name: "a dead job frees the place of a group", run: &group_freed_by_dead),
    Case(name: "the expiry of a lease frees the place of a group", run: &group_freed_by_expiry),
    Case(name: "a fetch that waits for a full group gets a job when an ack frees it", run: &group_wakes_on_ack),
    Case(name: "a fetch that waits for a full group gets a job when a retry frees it", run: &group_wakes_on_retry),
    Case(name: "a fetch that waits for a full group gets a job when a lease expires", run: &group_wakes_on_expiry),
  ]
end

private

QUEUE = "conformance"
OTHER = "other"
# Long enough that no lease of the fetchers runs out while they work.
LONG_LEASE_MS = 600_000
FETCHERS = 8
FETCHED_JOBS = 200
AWAIT_MS = 30_000
PENDING_MS = 100
# A fetch that waits for a group is woken when a lease ends: at once on a manual clock, and after the unit of the
# lease on a real one. It fails, for a backend that does not wake it, when its wait is over.
GROUP_WAIT_MS = 5_000
AWAIT_GRACE_MS = 1_000
ADVANCES = 600
ADVANCE_MS = 50
DAY_MS = 86_400_000

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

def keyed(key: String) -> Jobs.NewJob = Jobs.NewJob(queue: QUEUE, payload: key.bytes, unique_key: some(key))

def add(env: Env, new: Jobs.NewJob) -> Result[Jobs.Enqueued] = Jobs.enqueue(env.backend, new)

def lease_one(env: Env, queue: String) -> Result[Jobs.Lease]
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: queue, lease_ms: env.unit_ms))
  return error("conformance: a fetch of #{queue} gave no job", kind: "conformance.failed") if leases.empty?

  ok(leases[0])
end

def fetch_none(env: Env, queue: String) -> Result[Void]
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: queue))
  expect(leases.empty?, "a fetch of #{queue} gave #{leases.size} jobs, and should give none")
end

def counted(ready: Int, scheduled: Int, leased: Int, dead: Int) -> Jobs.Counts
  Jobs.Counts(ready: ready, scheduled: scheduled, leased: leased, dead: dead)
end

def expect_counts(env: Env, queue: String, want: Jobs.Counts) -> Result[Void]
  counts = try Jobs.counts(env.backend, queue)
  expect(counts == want, "the counts are #{counts}, and should be #{want}")
end

def advance(env: Env, ms: Int) -> Void
  env.clock.advance.call(ms)
end

def if_exact(env: Env, exact: Int, real: Int) -> Int
  return exact if env.exact

  real
end

# More than the unit that a lease lasts, by a margin that a real clock can tell.
def slack(env: Env) -> Int = if_exact(env, 1, env.unit_ms / 2)

# The lease of a job has run out.
def expire(env: Env) -> Void
  advance(env, env.unit_ms + slack(env))
end

# How long a job waits for its time, in a case that makes it wait.
def delay(env: Env) -> Int = if_exact(env, 10_000, env.unit_ms * 2)

# A time that is long enough that nothing is still waiting for it.
def long_wait(env: Env) -> Int = if_exact(env, DAY_MS, env.unit_ms * 2)

# Moves to the time `delay` ms from the call that set it: with the manual clock to a millisecond before, where
# nothing is due yet, and then to the time itself; with the real clock to a little after.
def reach(env: Env, delay: Int, queue: String) -> Result[Void]
  if env.exact
    advance(env, delay - 1)
    try fetch_none(env, queue)
    advance(env, 1)
  else
    advance(env, delay + slack(env))
  end

  ok()
end

# Moves the clock until the task ends, so that the case does not depend on when the fetch started to wait. A real clock
# moves by itself, so a short step is enough.
def advance_until[T](env: Env, task: Task[T], ms: Int) -> Result[T]
  attempts = 0
  while attempts < ADVANCES
    advance(env, if_exact(env, ms, ADVANCE_MS))
    case Task.await(task, ADVANCE_MS)
      Await.Done(value) -> return ok(value)
      Await.TimedOut -> attempts += 1
    end
  end

  error("conformance: a fetch that waits did not end when the clock moved", kind: "conformance.failed")
end

def roundtrip(env: Env) -> Result[Void]
  payload = try Bytes.from_list([0, 255, 128, 10, 13, 65])
  new = Jobs.NewJob(queue: QUEUE, payload: payload, max_attempts: 3, meta: {"trace": "t-1"})
  added = try Jobs.enqueue_all(env.backend, [new, job(QUEUE, "second")])
  try expect(added.size == 2, "enqueue_all of 2 jobs gave #{added.size} answers")
  try expect(added[0].id != added[1].id, "two jobs got the id #{added[0].id}")
  try expect(not added[0].duplicate, "a new job was a duplicate")
  now = env.clock.now.call()
  leases = try Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE, max: 2, lease_ms: env.unit_ms))
  try expect(leases.size == 2, "a fetch of 2 jobs gave #{leases.size}")
  held = leases[0]
  try expect(held.job.id == added[0].id, "the first job has the id #{held.job.id}, not #{added[0].id}")
  try expect(held.job.payload == payload, "the payload changed")
  try expect(held.job.attempt == 1, "the attempt is #{held.job.attempt}, and should be 1")
  try expect(held.job.queue == QUEUE and held.job.max_attempts == 3, "the queue or the max_attempts changed")
  try expect(held.job.meta == {"trace": "t-1"}, "the meta changed: #{held.job.meta}")
  try expect(held.job.last_error.none?, "a new job has the last_error #{held.job.last_error}")
  try expect(held.token != leases[1].token, "two leases share the token #{held.token}")
  if env.exact
    try expect(held.expires_at_ms == now + env.unit_ms, "the lease ends at #{held.expires_at_ms}")
    return expect(held.job.inserted_at_ms == now, "inserted_at_ms is #{held.job.inserted_at_ms}, not #{now}")
  end

  ok()
end

def empty_queue(env: Env) -> Result[Void] = fetch_none(env, QUEUE)

def queues_apart(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  try fetch_none(env, OTHER)
  try expect_counts(env, OTHER, counted(0, 0, 0, 0))
  try expect_counts(env, QUEUE, counted(1, 0, 0, 0))
  held = try lease_one(env, QUEUE)
  expect(held.job.queue == QUEUE, "the job is of the queue #{held.job.queue}")
end

# A fetch that waits, in a task of its own. It is still waiting a moment later: a backend that ignores `wait_ms` has
# answered by then, and a correct one cannot end a fetch that waits within PENDING_MS.
def spawn_waiting(env: Env, wait_ms: Int) -> Result[Task[Result[List[Jobs.Lease]]]]
  spawn_fetch(env, Jobs.Fetch(queue: QUEUE, lease_ms: env.unit_ms, wait_ms: wait_ms))
end

def spawn_fetch(env: Env, fetch: Jobs.Fetch) -> Result[Task[Result[List[Jobs.Lease]]]]
  waiting = Task.spawn do Jobs.fetch(env.backend, fetch) end

  case Task.await(waiting, PENDING_MS)
    Await.Done(_) -> error("conformance: a fetch that waits ended at once", kind: "conformance.failed")
    Await.TimedOut -> ok(waiting)
  end
end

def waiting_fetch(env: Env) -> Result[Void]
  waiting = try spawn_waiting(env, AWAIT_MS)
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

def waiting_fetch_times_out(env: Env) -> Result[Void]
  wait_ms = if_exact(env, 5_000, env.unit_ms)
  waiting = try spawn_waiting(env, wait_ms)
  answer = try advance_until(env, waiting, wait_ms)
  leases = try answer
  expect(leases.empty?, "a fetch that waited for nothing gave #{leases.size} jobs")
end

def waiting_fetch_scheduled(env: Env) -> Result[Void]
  at_ms = env.clock.now.call() + delay(env)
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "later".bytes, run_at_ms: at_ms))
  waiting = try spawn_waiting(env, 3_600_000)
  answer = try advance_until(env, waiting, delay(env))
  leases = try answer
  try expect(leases.size == 1, "the fetch that waited for a scheduled job gave #{leases.size} jobs, and should give 1")
  expect(leases[0].job.run_at_ms == at_ms, "the job runs at #{leases[0].job.run_at_ms}, not #{at_ms}")
end

def lease_expires(env: Env) -> Result[Void]
  added = try add(env, job(QUEUE, "a"))
  first = try lease_one(env, QUEUE)
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, counted(0, 0, 1, 0))
  expire(env)
  second = try lease_one(env, QUEUE)
  try expect(second.job.id == added.id, "the job came back with the id #{second.job.id}")
  try expect(second.job.attempt == 2, "the attempt is #{second.job.attempt} after an expiry, and should be 2")
  try expect(second.token != first.token, "a new delivery has the token of the old one")
  try expect_kind(Jobs.ack(env.backend, first), "jobs.lease_lost", "an ack with the token of the first delivery")
  Jobs.ack(env.backend, second)
end

def stale_token(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  first = try lease_one(env, QUEUE)
  expire(env)
  second = try lease_one(env, QUEUE)
  try expect_kind(
    Jobs.nack(env.backend, first, Jobs.Nack.Dead("late")),
    "jobs.lease_lost",
    "a nack of an old delivery",
  )

  try expect_kind(Jobs.extend(env.backend, first, 5_000), "jobs.lease_lost", "an extend of an old delivery")
  try expect_counts(env, QUEUE, counted(0, 0, 1, 0))
  Jobs.ack(env.backend, second)
end

# No fetch comes between the end of the lease and the calls: the backend must know by itself that the lease is over.
def lease_lost_after_expiry(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  expire(env)
  try expect_kind(Jobs.ack(env.backend, held), "jobs.lease_lost", "an ack after the lease ran out")
  try expect_kind(Jobs.nack(env.backend, held, Jobs.Nack.Release), "jobs.lease_lost", "a nack after the lease ran out")
  try expect_kind(Jobs.extend(env.backend, held, 5_000), "jobs.lease_lost", "an extend after the lease ran out")
  try expect_counts(env, QUEUE, counted(1, 0, 0, 0))
  again = try lease_one(env, QUEUE)
  expect(again.job.attempt == 2, "the attempt is #{again.job.attempt} after an expiry, and should be 2")
end

def ack_once(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  try Jobs.ack(env.backend, held)
  try expect_counts(env, QUEUE, counted(0, 0, 0, 0))
  expect_kind(Jobs.ack(env.backend, held), "jobs.lease_lost", "a second ack")
end

def retry_waits(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, Jobs.Nack.Retry(Jobs.Later(at_ms: env.clock.now.call() + delay(env))))
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, counted(0, 1, 0, 0))
  try reach(env, delay(env), QUEUE)
  again = try lease_one(env, QUEUE)
  expect(again.job.attempt == 2, "the attempt is #{again.job.attempt} after a retry, and should be 2")
end

def release_keeps_attempt(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, Jobs.Nack.Release)
  again = try lease_one(env, QUEUE)
  expect(again.job.attempt == 1, "the attempt is #{again.job.attempt} after a release, and should be 1")
end

def last_error(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  first = try lease_one(env, QUEUE)
  try expect(first.job.last_error == none, "the first delivery has the last_error #{first.job.last_error}")
  try Jobs.nack(env.backend, first, retry_now(env, some("the server is down")))
  second = try lease_one(env, QUEUE)
  try expect(second.job.last_error == some("the server is down"), "the last_error is #{second.job.last_error}")
  try Jobs.nack(env.backend, second, retry_now(env, none))
  third = try lease_one(env, QUEUE)
  expect(
    third.job.last_error == some("the server is down"),
    "the last_error is #{third.job.last_error} after a silent retry",
  )
end

def retry_now(env: Env, message: Optional[String]) -> Jobs.Nack
  Jobs.Nack.Retry(Jobs.Later(at_ms: env.clock.now.call(), error: message))
end

def dead_for_good(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, Jobs.Nack.Dead("bad input"))
  try expect_counts(env, QUEUE, counted(0, 0, 0, 1))
  advance(env, long_wait(env))
  fetch_none(env, QUEUE)
end

def last_attempt_expires(env: Env) -> Result[Void]
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, max_attempts: 2))
  _ = try lease_one(env, QUEUE)
  expire(env)
  second = try lease_one(env, QUEUE)
  try expect(second.job.attempt == 2, "the second delivery has the attempt #{second.job.attempt}")
  expire(env)
  try fetch_none(env, QUEUE)
  expect_counts(env, QUEUE, counted(0, 0, 0, 1))
end

def last_attempt_retries(env: Env) -> Result[Void]
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, max_attempts: 1))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, Jobs.Nack.Retry(Jobs.Later(at_ms: env.clock.now.call())))
  try fetch_none(env, QUEUE)
  expect_counts(env, QUEUE, counted(0, 0, 0, 1))
end

# A lease is over at its end and not before. A real clock cannot be stopped at a millisecond, so only a manual one is
# checked.
def lease_end(env: Env) -> Result[Void]
  return ok() if not env.exact

  _ = try add(env, job(QUEUE, "a"))
  _ = try lease_one(env, QUEUE)
  advance(env, env.unit_ms - 1)
  try expect_counts(env, QUEUE, counted(0, 0, 1, 0))
  advance(env, 1)
  expect_counts(env, QUEUE, counted(1, 0, 0, 0))
end

# The lease is moved to four units from now. The job stays leased past the first end, and comes back after the new one.
def extend_moves(env: Env) -> Result[Void]
  _ = try add(env, job(QUEUE, "a"))
  held = try lease_one(env, QUEUE)
  now = env.clock.now.call()
  longer = try Jobs.extend(env.backend, held, env.unit_ms * 4)
  try expect(longer.token == held.token, "an extend changed the token")
  if env.exact
    try expect(longer.expires_at_ms == now + env.unit_ms * 4, "the lease ends at #{longer.expires_at_ms}")
  end

  advance(env, env.unit_ms * 2)
  try fetch_none(env, QUEUE)
  advance(env, if_exact(env, env.unit_ms * 2 - 1, env.unit_ms))
  try fetch_none(env, QUEUE)
  advance(env, if_exact(env, 2, env.unit_ms + slack(env)))
  again = try lease_one(env, QUEUE)
  try expect(again.job.attempt == 2, "the attempt is #{again.job.attempt} after the new end, and should be 2")
  expect_kind(Jobs.ack(env.backend, longer), "jobs.lease_lost", "an ack of the extended lease after it ran out")
end

def not_early(env: Env) -> Result[Void]
  at_ms = env.clock.now.call() + delay(env)
  _ = try add(env, Jobs.NewJob(queue: QUEUE, payload: "a".bytes, run_at_ms: at_ms))
  try fetch_none(env, QUEUE)
  try expect_counts(env, QUEUE, counted(0, 1, 0, 0))
  try reach(env, delay(env), QUEUE)
  try expect_counts(env, QUEUE, counted(1, 0, 0, 0))
  _ = try lease_one(env, QUEUE)
  ok()
end

def unique_key(env: Env) -> Result[Void]
  first = try add(env, keyed("k"))
  second = try add(env, keyed("k"))
  try expect(second.duplicate and second.id == first.id, "a second job of the key is #{second}, not a duplicate")
  elsewhere = try add(env, Jobs.NewJob(queue: OTHER, payload: "a".bytes, unique_key: some("k")))
  try expect(not elsewhere.duplicate, "the same key in another queue was a duplicate")
  held = try lease_one(env, QUEUE)
  third = try add(env, keyed("k"))
  try expect(third.duplicate, "a leased job did not hold its key")
  try Jobs.ack(env.backend, held)
  fourth = try add(env, keyed("k"))
  try expect(not fourth.duplicate, "the key is not free after the ack")
  dying = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, dying, Jobs.Nack.Dead("no"))
  fifth = try add(env, keyed("k"))
  expect(not fifth.duplicate, "the key is not free after the job is dead")
end

# The key is free when the job is dead, however it died: by expiry or by a retry on its last attempt (the explicit dead
# is in `unique_key`).
def unique_key_dies(env: Env) -> Result[Void]
  try dies_by_expiry(env)
  dies_by_retry(env)
end

def last_attempt_job(key: String) -> Jobs.NewJob
  Jobs.NewJob(queue: QUEUE, payload: key.bytes, unique_key: some(key), max_attempts: 1)
end

def dies_by_expiry(env: Env) -> Result[Void]
  _ = try add(env, last_attempt_job("expiry"))
  _ = try lease_one(env, QUEUE)
  expire(env)
  try expect_counts(env, QUEUE, counted(0, 0, 0, 1))
  again = try add(env, keyed("expiry"))
  try expect(not again.duplicate, "the key is not free after the job died by expiry")
  fresh = try lease_one(env, QUEUE)
  Jobs.ack(env.backend, fresh)
end

def dies_by_retry(env: Env) -> Result[Void]
  _ = try add(env, last_attempt_job("retry"))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, retry_now(env, none))
  again = try add(env, keyed("retry"))
  expect(not again.duplicate, "the key is not free after the job died by a retry on its last attempt")
end

def expect_duplicate(env: Env, first: Jobs.Enqueued, when: String) -> Result[Void]
  again = try add(env, keyed("held"))
  expect(again.duplicate and again.id == first.id, "the key is free #{when}: the job got the id #{again.id}")
end

# The key is held while the job is not finished, whatever brought it back: a retry, a release, a lease that ran out.
def unique_key_held(env: Env) -> Result[Void]
  first = try add(env, keyed("held"))
  held = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, held, Jobs.Nack.Retry(Jobs.Later(at_ms: env.clock.now.call() + delay(env))))
  try expect_duplicate(env, first, "after a retry")
  try reach(env, delay(env), QUEUE)
  released = try lease_one(env, QUEUE)
  try Jobs.nack(env.backend, released, Jobs.Nack.Release)
  try expect_duplicate(env, first, "after a release")
  _ = try lease_one(env, QUEUE)
  expire(env)
  try expect_duplicate(env, first, "after a lease ran out")
  last = try lease_one(env, QUEUE)
  try Jobs.ack(env.backend, last)
  fresh = try add(env, keyed("held"))
  expect(not fresh.duplicate, "the key is not free after the ack")
end

def same_key_in_batch(env: Env) -> Result[Void]
  added = try Jobs.enqueue_all(env.backend, [keyed("batch"), keyed("batch"), job(QUEUE, "other")])
  try expect(added.size == 3, "enqueue_all of 3 jobs gave #{added.size} answers")
  try expect(not added[0].duplicate, "the first job of a key was a duplicate")
  try expect(added[1].duplicate and added[1].id == added[0].id, "the second job of the key is #{added[1]}")
  try expect(not added[2].duplicate, "a job with no key was a duplicate")
  expect_counts(env, QUEUE, counted(2, 0, 0, 0))
end

def all_or_nothing(env: Env) -> Result[Void]
  bad = Jobs.NewJob(queue: QUEUE, payload: "bad".bytes, max_attempts: 0)
  failed = Jobs.enqueue_all(env.backend, [job(QUEUE, "a"), bad, job(QUEUE, "b")])
  try expect_kind(failed, "argument", "an enqueue_all with a job of 0 attempts")
  try expect_counts(env, QUEUE, counted(0, 0, 0, 0))
  added = try Jobs.enqueue_all(env.backend, [job(QUEUE, "a"), job(QUEUE, "b")])
  try expect(added.size == 2, "enqueue_all of 2 jobs gave #{added.size} answers")
  expect_counts(env, QUEUE, counted(2, 0, 0, 0))
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
  held = try lease_one(env, QUEUE)
  Jobs.close(env.backend, 1_000)
  try expect_kind(Jobs.enqueue(env.backend, job(QUEUE, "b")), "jobs.closed", "an enqueue after close")
  try expect_kind(Jobs.fetch(env.backend, Jobs.Fetch(queue: QUEUE)), "jobs.closed", "a fetch after close")
  try expect_kind(Jobs.ack(env.backend, held), "jobs.closed", "an ack after close")
  try expect_kind(Jobs.nack(env.backend, held, Jobs.Nack.Release), "jobs.closed", "a nack after close")
  try expect_kind(Jobs.extend(env.backend, held, env.unit_ms), "jobs.closed", "an extend after close")
  try expect_kind(Jobs.counts(env.backend, QUEUE), "jobs.closed", "counts after close")
  Jobs.close(env.backend, 1_000)
  expect_kind(Jobs.counts(env.backend, QUEUE), "jobs.closed", "counts after a second close")
end

def closed_while_waiting(env: Env) -> Result[Void]
  waiting = try spawn_waiting(env, AWAIT_MS)
  Jobs.close(env.backend, 1_000)
  case Task.await(waiting, AWAIT_MS)
    Await.Done(answer) -> expect_kind(answer, "jobs.closed", "a fetch that waited when the backend was closed")
    Await.TimedOut -> error("conformance: a fetch that waits did not end at close", kind: "conformance.failed")
  end
end

def grouped(group: String, text: String) -> Jobs.NewJob
  Jobs.NewJob(queue: QUEUE, payload: text.bytes, group: some(group))
end

def limited(env: Env, max: Int, limit: Int) -> Jobs.Fetch
  Jobs.Fetch(queue: QUEUE, max: max, lease_ms: env.unit_ms, max_per_group: limit)
end

def payloads(leases: List[Jobs.Lease]) -> List[String]
  leases.map(->(held) { String.from_bytes(held.job.payload).unwrap_or("?") })
end

def expect_payloads(leases: List[Jobs.Lease], want: List[String]) -> Result[Void]
  expect(payloads(leases) == want, "the fetch gave #{payloads(leases)}, and should give #{want}")
end

def group_values(env: Env) -> Result[Void]
  _ = try add(env, grouped("g", "a"))
  held = try lease_one(env, QUEUE)
  try expect(held.job.group == some("g"), "the group of the job is #{held.job.group}")
  empty = Jobs.NewJob(queue: QUEUE, payload: "b".bytes, group: some(""))
  try expect_kind(add(env, empty), "argument", "a job with an empty group")
  expect_kind(Jobs.fetch(env.backend, limited(env, 1, -1)), "argument", "a fetch with a negative max_per_group")
end

def full_group_skipped(env: Env) -> Result[Void]
  for text in ["a1", "a2", "a3"]
    _ = try add(env, grouped("a", text))
  end

  _ = try add(env, grouped("b", "b1"))
  _ = try add(env, job(QUEUE, "plain"))
  first = try Jobs.fetch(env.backend, limited(env, 10, 2))
  try expect_payloads(first, ["a1", "a2", "b1", "plain"])
  second = try Jobs.fetch(env.backend, limited(env, 10, 2))
  try expect_payloads(second, [])
  try expect_counts(env, QUEUE, counted(1, 0, 4, 0))
  try Jobs.ack(env.backend, first[0])
  third = try Jobs.fetch(env.backend, limited(env, 10, 2))
  expect_payloads(third, ["a3"])
end

def groups_per_queue(env: Env) -> Result[Void]
  _ = try add(env, grouped("a", "here"))
  _ = try Jobs.enqueue(env.backend, Jobs.NewJob(queue: OTHER, payload: "there".bytes, group: some("a")))
  _ = try lease_one(env, QUEUE)
  elsewhere = try Jobs.fetch(env.backend, Jobs.Fetch(queue: OTHER, lease_ms: env.unit_ms, max_per_group: 1))
  expect_payloads(elsewhere, ["there"])
end

def no_limit(env: Env) -> Result[Void]
  for text in ["a1", "a2", "a3"]
    _ = try add(env, grouped("a", text))
  end

  unlimited = try Jobs.fetch(env.backend, limited(env, 3, 0))
  try expect_payloads(unlimited, ["a1", "a2", "a3"])
  for text in ["p1", "p2", "p3"]
    _ = try add(env, job(QUEUE, text))
  end

  plain = try Jobs.fetch(env.backend, limited(env, 3, 1))
  expect_payloads(plain, ["p1", "p2", "p3"])
end

# A group of limit 1 with one lease live and a job that waits for it: `end_lease` ends that lease, and the job is then
# delivered (the job of the lease itself may come back first).
def group_freed(env: Env, end_lease: Fn[Env, Jobs.Lease, Result[Void]]) -> Result[Void]
  _ = try add(env, grouped("g", "g1"))
  _ = try add(env, grouped("g", "g2"))
  first = try Jobs.fetch(env.backend, limited(env, 1, 1))
  try expect_payloads(first, ["g1"])
  blocked = try Jobs.fetch(env.backend, limited(env, 1, 1))
  try expect_payloads(blocked, [])
  try end_lease.call(env, first[0])
  freed = try Jobs.fetch(env.backend, limited(env, 1, 1))
  expect(freed.size == 1, "the group is not free after its lease ended: the fetch gave #{freed.size} jobs")
end

def group_freed_by_ack(env: Env) -> Result[Void] = group_freed(env, ->(e, held) { Jobs.ack(e.backend, held) })

def group_freed_by_retry(env: Env) -> Result[Void]
  group_freed(env, ->(e, held) { Jobs.nack(e.backend, held, retry_now(e, none)) })
end

def group_freed_by_release(env: Env) -> Result[Void]
  group_freed(env, ->(e, held) { Jobs.nack(e.backend, held, Jobs.Nack.Release) })
end

def group_freed_by_dead(env: Env) -> Result[Void]
  group_freed(env, ->(e, held) { Jobs.nack(e.backend, held, Jobs.Nack.Dead("no")) })
end

def group_freed_by_expiry(env: Env) -> Result[Void]
  group_freed(
    env,
    ->(e, _held) {
      expire(e)
      ok()
    },
  )
end

# A fetch that waits for a group that is full: `end_lease` ends the lease that fills it, and the fetch ends with a job.
def group_wakes(env: Env, end_lease: Fn[Env, Jobs.Lease, Result[Void]]) -> Result[Void]
  _ = try add(env, grouped("g", "g1"))
  _ = try add(env, grouped("g", "g2"))
  first = try Jobs.fetch(env.backend, limited(env, 1, 1))
  waiting_for = Jobs.Fetch(queue: QUEUE, lease_ms: env.unit_ms, wait_ms: GROUP_WAIT_MS, max_per_group: 1)
  waiting = try spawn_fetch(env, waiting_for)
  try end_lease.call(env, first[0])
  case Task.await(waiting, GROUP_WAIT_MS + AWAIT_GRACE_MS)
    Await.Done(answer) -> got_one(answer)
    Await.TimedOut -> error("conformance: a fetch that waits for a group did not end", kind: "conformance.failed")
  end
end

def group_wakes_on_ack(env: Env) -> Result[Void] = group_wakes(env, ->(e, held) { Jobs.ack(e.backend, held) })

def group_wakes_on_retry(env: Env) -> Result[Void]
  group_wakes(env, ->(e, held) { Jobs.nack(e.backend, held, retry_now(e, none)) })
end

def group_wakes_on_expiry(env: Env) -> Result[Void]
  group_wakes(
    env,
    ->(e, _held) {
      expire(e)
      ok()
    },
  )
end

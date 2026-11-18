import Jobs from "../jobs"
import Store from "../src/store"

private

NOW = 1_000_000
LEASE_MS = 1_000

def new_job(max_attempts: Int) -> Jobs.NewJob = Jobs.NewJob(queue: "q", payload: "a".bytes, max_attempts: max_attempts)

def keyed(key: String) -> Jobs.NewJob = Jobs.NewJob(queue: "q", payload: key.bytes, unique_key: some(key))

def retry(at_ms: Int, message: Optional[String]) -> Jobs.Nack
  Jobs.Nack.Retry(Jobs.Later(at_ms: at_ms, error: message))
end

def with_job(new: Jobs.NewJob) -> Result[Store.Store]
  added = try Store.enqueue(Store.empty(10, 10), NOW, [new])
  ok(added.store)
end

# One more job in the store, and whether it was a duplicate.
def add(store: Store.Store, new: Jobs.NewJob) -> Result[Store.Added] = Store.enqueue(store, NOW, [new])

def take(store: Store.Store, now: Int) -> Result[Store.Taken]
  Store.take(store, now, Jobs.Fetch(queue: "q", lease_ms: LEASE_MS))
end

# The store with one job that is leased once.
def leased(new: Jobs.NewJob) -> Result[Store.Taken] = take(try with_job(new), NOW)

def counts(store: Store.Store, now: Int) -> Jobs.Counts = Store.counts(store, now, "q")

def counted(ready: Int, scheduled: Int, leased: Int, dead: Int) -> Jobs.Counts
  Jobs.Counts(ready: ready, scheduled: scheduled, leased: leased, dead: dead)
end

def in_group(group: String, text: String) -> Jobs.NewJob
  Jobs.NewJob(queue: "q", payload: text.bytes, group: some(group))
end

# The store with the jobs of group "g" added, a fetch of up to `max` with a limit, and what it gave.
def fetch_limited(store: Store.Store, now: Int, max: Int, limit: Int) -> Result[Store.Taken]
  Store.take(store, now, Jobs.Fetch(queue: "q", max: max, lease_ms: LEASE_MS, max_per_group: limit))
end

# A group of `size` jobs with one leased under a limit of 1, and the fetch that then finds the group full.
def held_group(size: Int) -> Result[Store.Taken]
  jobs = (1..size).map(->(n) { in_group("g", "j#{n}") })
  added = try Store.enqueue(Store.empty(5000, 10), NOW, jobs)
  first = try fetch_limited(added.store, NOW, 1, 1)
  fetch_limited(first.store, NOW, 1, 1)
end

def texts(taken: Store.Taken) -> List[String]
  taken.leases.map(->(held) { String.from_bytes(held.job.payload).unwrap_or("?") })
end

def lost?[T](result: Result[T]) -> Bool
  case result
    ok(_) -> false
    error(e) -> e.is_a?("jobs.lease_lost")
  end
end

def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def duplicate?(store: Store.Store, key: String) -> Result[Bool]
  added = try add(store, keyed(key))
  ok(added.enqueued[0].duplicate)
end

def main() -> Void
  Test.run([
    Test.test("a lease that ran out or was replaced is lost for ack, nack and extend") do
      taken = try leased(new_job(5))
      held = taken.leases[0]
      over = Store.tick(taken.store, NOW + LEASE_MS)
      try Test.eq(lost?(Store.ack(over, held)), true)
      try Test.eq(lost?(Store.nack(over, held, Jobs.Nack.Release)), true)
      try Test.eq(lost?(Store.extend(over, NOW + LEASE_MS, held, 5_000)), true)
      other = held.with(token: "another delivery")
      try Test.eq(lost?(Store.ack(taken.store, other)), true)
      return Test.eq(lost?(Store.ack(taken.store, held)), false)
    end,
    Test.test("tick gives a lease that ran out back, with the delivery counted, and not before its end") do
      taken = try leased(new_job(5))
      try Test.eq(counts(Store.tick(taken.store, NOW + LEASE_MS - 1), NOW + LEASE_MS - 1), counted(0, 0, 1, 0))
      over = Store.tick(taken.store, NOW + LEASE_MS)
      try Test.eq(counts(over, NOW + LEASE_MS), counted(1, 0, 0, 0))
      again = try take(over, NOW + LEASE_MS)
      return Test.eq(again.leases[0].job.attempt, 2)
    end,
    Test.test("a lease that runs out on the last attempt makes the job dead, with the error") do
      taken = try leased(new_job(1))
      over = Store.tick(taken.store, NOW + LEASE_MS)
      try Test.eq(counts(over, NOW + LEASE_MS), counted(0, 0, 0, 1))
      return Test.eq(over.dead[0].job.last_error, some("the lease expired on the last attempt"))
    end,
    Test.test("extend moves the end of the lease, and the job comes back at the new end") do
      taken = try leased(new_job(5))
      extended = try Store.extend(taken.store, NOW + 500, taken.leases[0], 5_000)
      try Test.eq(extended.lease.expires_at_ms, NOW + 5_500)
      try Test.eq(counts(Store.tick(extended.store, NOW + 5_499), NOW + 5_499), counted(0, 0, 1, 0))
      return Test.eq(counts(Store.tick(extended.store, NOW + 5_500), NOW + 5_500), counted(1, 0, 0, 0))
    end,
    Test.test("a job is not delivered before its run_at_ms") do
      store = try with_job(Jobs.NewJob(queue: "q", payload: "a".bytes, run_at_ms: NOW + 1_000))
      early = try take(store, NOW + 999)
      try Test.eq(early.leases.size, 0)
      try Test.eq(counts(store, NOW + 999), counted(0, 1, 0, 0))
      due = try take(store, NOW + 1_000)
      return Test.eq(due.leases.size, 1)
    end,
    Test.test("a unique key is held through a retry, a release and an expired lease") do
      first = try with_job(keyed("k"))
      taken = try take(first, NOW)
      retried = try Store.nack(taken.store, taken.leases[0], retry(NOW + 5_000, none))
      try Test.eq(try duplicate?(retried, "k"), true)
      again = try take(retried, NOW + 5_000)
      released = try Store.nack(again.store, again.leases[0], Jobs.Nack.Release)
      try Test.eq(try duplicate?(released, "k"), true)
      third = try take(released, NOW + 5_000)
      over = Store.tick(third.store, NOW + 5_000 + LEASE_MS)
      return Test.eq(try duplicate?(over, "k"), true)
    end,
    Test.test("a unique key is free when the job is acked or dead, and not for another queue's key") do
      taken = try leased(keyed("k"))
      acked = try Store.ack(taken.store, taken.leases[0])
      try Test.eq(try duplicate?(acked, "k"), false)
      second = try leased(keyed("k"))
      dead = try Store.nack(second.store, second.leases[0], Jobs.Nack.Dead("no"))
      try Test.eq(try duplicate?(dead, "k"), false)
      held = try with_job(keyed("k"))
      elsewhere = Jobs.NewJob(queue: "other", payload: "a".bytes, unique_key: some("k"))
      added = try add(held, elsewhere)
      return Test.eq(added.enqueued[0].duplicate, false)
    end,
    Test.test("a batch adds every job or none, and a key in it is one job") do
      bad = Jobs.NewJob(queue: "q", payload: "bad".bytes, max_attempts: 0)
      empty = Store.empty(2, 10)
      try Test.eq(kind_of(Store.enqueue(empty, NOW, [new_job(5), bad, new_job(5)])), "argument")
      try Test.eq(kind_of(Store.enqueue(empty, NOW, [new_job(5), new_job(5), new_job(5)])), "jobs.full")
      try Test.eq(counts(empty, NOW), counted(0, 0, 0, 0))
      batch = try Store.enqueue(Store.empty(10, 10), NOW, [keyed("k"), keyed("k"), new_job(5)])
      try Test.eq(batch.enqueued.map(->(one) { one.duplicate }), [false, true, false])
      try Test.eq(batch.enqueued[1].id, batch.enqueued[0].id)
      return Test.eq(counts(batch.store, NOW), counted(2, 0, 0, 0))
    end,
    Test.test("a release does not count the attempt") do
      taken = try leased(new_job(5))
      released = try Store.nack(taken.store, taken.leases[0], Jobs.Nack.Release)
      again = try take(released, NOW)
      return Test.eq(again.leases[0].job.attempt, 1)
    end,
    Test.test("a fetch with a limit passes over a full group, counts its own leases, and takes the job later") do
      added = try Store.enqueue(Store.empty(10, 10), NOW, [in_group("g", "a1"), in_group("g", "a2"), new_job(5)])
      first = try fetch_limited(added.store, NOW, 3, 1)
      try Test.eq(texts(first), ["a1", "a"])
      try Test.eq(texts(try fetch_limited(first.store, NOW, 3, 1)), [])
      acked = try Store.ack(first.store, first.leases[0])
      return Test.eq(texts(try fetch_limited(acked, NOW, 3, 1)), ["a2"])
    end,
    Test.test(
      "a fetch passes over a full group in as many steps for 10 jobs as for 1000, and over each full group once",
    ) do
      small = try held_group(10)
      big = try held_group(1000)
      try Test.eq(small.leases, [])
      try Test.eq(small.held_back, true)
      try Test.eq(big.visits, small.visits)
      try Test.eq(big.visits <= 3, true)
      many: List[Jobs.NewJob] = []
      for group in ["a", "b", "c", "d"]
        many = many + (1..50).map(->(n) { in_group(group, "#{group}#{n}") })
      end

      added = try Store.enqueue(Store.empty(5000, 10), NOW, many)
      first = try fetch_limited(added.store, NOW, 4, 1)
      again = try fetch_limited(first.store, NOW, 4, 1)
      try Test.eq(again.leases, [])
      return Test.eq(again.visits <= 5, true)
    end,
    Test.test("a job that comes back ahead of its group again and again does not make a held fetch visit more") do
      added = try Store.enqueue(
        Store.empty(100, 10),
        NOW,
        [in_group("g", "s1"), in_group("g", "s2"), in_group("g", "s3")],
      )

      store = added.store
      for _ in 1..300
        taken = try fetch_limited(store, NOW, 1, 0)
        store = try Store.nack(taken.store, taken.leases[0], Jobs.Nack.Release)
      end

      first = try fetch_limited(store, NOW, 1, 1)
      try Test.eq(texts(first), ["s1"])
      held = try fetch_limited(first.store, NOW, 1, 1)
      try Test.eq(held.leases, [])
      try Test.eq(held.visits <= 12, true)
      freed = try Store.ack(held.store, first.leases[0])
      return Test.eq(texts(try fetch_limited(freed, NOW, 1, 1)), ["s2"])
    end,
    Test.test("jobs of a group that come each ahead of the one before do not make a held fetch visit more") do
      jobs = (1..300).map(
        ->(n) { Jobs.NewJob(queue: "q", payload: "j#{n}".bytes, group: some("g"), run_at_ms: NOW - n) },
      )

      added = try Store.enqueue(Store.empty(1000, 10), NOW, jobs)
      first = try fetch_limited(added.store, NOW, 1, 1)
      try Test.eq(texts(first), ["j300"])
      held = try fetch_limited(first.store, NOW, 1, 1)
      try Test.eq(held.leases, [])
      return Test.eq(held.visits <= 12, true)
    end,
    Test.test(
      "the next job time is a job that is not due: a held job has none, and the end of a lease is its own time",
    ) do
      added = try Store.enqueue(
        Store.empty(10, 10),
        NOW,
        [in_group("g", "x"), in_group("g", "y"), Jobs.NewJob(queue: "q", payload: "z".bytes, run_at_ms: NOW + 500)],
      )

      first = try fetch_limited(added.store, NOW, 1, 1)
      try Test.eq(Store.next_job_at(first.store, "q", NOW), some(NOW + 500))
      try Test.eq(Store.next_expiry(first.store), some(NOW + LEASE_MS))
      only_held = try Store.enqueue(Store.empty(10, 10), NOW, [in_group("g", "x"), in_group("g", "y")])
      held = try fetch_limited(only_held.store, NOW, 1, 1)
      try Test.eq(Store.next_job_at(held.store, "q", NOW), none)
      return Test.eq(Store.next_expiry(held.store), some(NOW + LEASE_MS))
    end,
    Test.test(
      "the count of changes moves when a job waits or a lease ends, and not when a fetch takes or finds nothing",
    ) do
      added = try Store.enqueue(Store.empty(10, 10), NOW, [in_group("g", "x"), in_group("g", "y")])
      first = try fetch_limited(added.store, NOW, 1, 1)
      held = try fetch_limited(first.store, NOW, 1, 1)
      try Test.eq(first.store.changes, added.store.changes)
      try Test.eq(held.store.changes, added.store.changes)
      try Test.eq((try Store.ack(first.store, first.leases[0])).changes, added.store.changes + 1)
      return Test.eq((try add(first.store, in_group("g", "z"))).store.changes, added.store.changes + 1)
    end,
    Test.test("every end of a lease frees its group: ack, retry, release, dead, expiry and a fetch nobody got") do
      added = try Store.enqueue(Store.empty(10, 10), NOW, [in_group("g", "x"), in_group("g", "y")])
      first = try fetch_limited(added.store, NOW, 1, 1)
      held = first.leases[0]
      ends = [
        try Store.ack(first.store, held),
        try Store.nack(first.store, held, retry(NOW, none)),
        try Store.nack(first.store, held, Jobs.Nack.Release),
        try Store.nack(first.store, held, Jobs.Nack.Dead("no")),
        Store.tick(first.store, NOW + LEASE_MS),
        Store.untake(first.store, first.leases),
      ]

      for after in ends
        try Test.eq(texts(try fetch_limited(after, NOW + LEASE_MS, 1, 1)).size, 1)
      end

      return Test.eq(texts(try fetch_limited(first.store, NOW, 1, 1)), [])
    end,
    Test.test("a retry keeps what went wrong for the next delivery, and a retry with no error keeps the last one") do
      taken = try leased(new_job(5))
      failed = try Store.nack(taken.store, taken.leases[0], retry(NOW, some("the server is down")))
      second = try take(failed, NOW)
      try Test.eq(second.leases[0].job.last_error, some("the server is down"))
      silent = try Store.nack(second.store, second.leases[0], retry(NOW, none))
      third = try take(silent, NOW)
      return Test.eq(third.leases[0].job.last_error, some("the server is down"))
    end,
    Test.test("jobs that nobody received go back without counting the delivery") do
      taken = try leased(new_job(5))
      try Test.eq(taken.leases[0].job.attempt, 1)
      back = Store.untake(taken.store, taken.leases)
      again = try take(back, NOW)
      try Test.eq(again.leases[0].job.attempt, 1)
      return Test.eq(counts(again.store, NOW), counted(0, 0, 1, 0))
    end,
    Test.test("a dead job keeps the error, whether it was killed or ran out of attempts") do
      taken = try leased(new_job(5))
      killed = try Store.nack(taken.store, taken.leases[0], Jobs.Nack.Dead("bad input"))
      try Test.eq(killed.dead[0].job.last_error, some("bad input"))
      last = try leased(new_job(1))
      retried = try Store.nack(last.store, last.leases[0], retry(NOW, none))
      try Test.eq(retried.dead[0].job.last_error, some("no attempts left"))
      said = try Store.nack(last.store, last.leases[0], retry(NOW, some("boom")))
      return Test.eq(said.dead[0].job.last_error, some("boom"))
    end,
  ])
end

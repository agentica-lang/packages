import Jobs from "../jobs"
import Store from "../src/store"

private

NOW = 1_000_000

def new_job(max_attempts: Int) -> Jobs.NewJob = Jobs.NewJob(queue: "q", payload: "a".bytes, max_attempts: max_attempts)

# A store with one job that is leased once, for `lease_ms`.
def leased(max_attempts: Int, lease_ms: Int) -> Result[Store.Taken]
  added = try Store.enqueue(Store.empty(10, 10), NOW, [new_job(max_attempts)])
  Store.take(added.store, NOW, Jobs.Fetch(queue: "q", lease_ms: lease_ms))
end

def main() -> Void
  Test.run([
    Test.test("jobs that nobody received go back without counting the delivery") do
      taken = try leased(5, 1_000)
      try Test.eq(taken.leases[0].job.attempt, 1)
      back = Store.untake(taken.store, taken.leases)
      again = try Store.take(back, NOW, Jobs.Fetch(queue: "q"))
      try Test.eq(again.leases[0].job.attempt, 1)
      return Test.eq(Store.counts(again.store, NOW, "q"), Jobs.Counts(ready: 0, scheduled: 0, leased: 1, dead: 0))
    end,
    Test.test("a dead job keeps the reason, whether it was killed, ran out of lease or ran out of attempts") do
      taken = try leased(5, 1_000)
      killed = try Store.nack(taken.store, taken.leases[0], Jobs.Nack.Dead("bad input"))
      try Test.eq(killed.dead[0].job.last_error, some("bad input"))
      only = try leased(1, 1_000)
      expired = Store.tick(only.store, NOW + 1_000)
      try Test.eq(expired.dead[0].job.last_error, some("the lease expired on the last attempt"))
      last = try leased(1, 1_000)
      retried = try Store.nack(last.store, last.leases[0], Jobs.Nack.Retry(NOW))
      return Test.eq(retried.dead[0].job.last_error, some("no attempts left"))
    end,
  ])
end

import Jobs from "../jobs"
import Parked from "../src/parked"
import Store from "../src/store"
import Wake from "../src/wake"

private

NOW = 1_000_000

def in_group(group: String, text: String) -> Jobs.NewJob
  Jobs.NewJob(queue: "q", payload: text.bytes, group: some(group))
end

def main() -> Void
  Test.run([
    Test.test(
      "a fetch that a full group holds wakes the actor at the end of the lease, or when it looks again, and not at once",
    ) do
      added = try Store.enqueue(Store.empty(10, 10), NOW, [in_group("g", "x"), in_group("g", "y")])
      fetch = Jobs.Fetch(queue: "q", lease_ms: 30, max_per_group: 1)
      first = try Store.take(added.store, NOW, fetch)
      held = try Store.take(first.store, NOW, fetch)
      reply: Channel[Result[List[Jobs.Lease]]] = Channel.new(1)
      until = Parked.Until(ms: NOW + 100_000, real_ms: 100_000)
      waiting = Parked.park(Parked.empty(), fetch, until, reply)
      try Test.eq(Wake.in_ms(held.store, Parked.empty(), NOW, 0), none)
      try Test.eq(Wake.in_ms(held.store, waiting, NOW, 0), some(30))
      looking = Parked.look(waiting, waiting.waiters[1], Parked.Looked(changes: 1, until_ms: some(NOW + 10)))
      try Test.eq(Wake.in_ms(held.store, looking, NOW, 0), some(10))
      return Test.eq(Wake.in_ms(Store.empty(10, 10), waiting, NOW, 0), some(Wake.CAP_MS))
    end,
  ])
end

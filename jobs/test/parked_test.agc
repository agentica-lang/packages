import Jobs from "../jobs"
import Parked from "../src/parked"

def main() -> Void
  Test.run([
    Test.test(
      "the time to look again is the first job that a waiter saw as not due, and is dropped when it has passed",
    ) do
      reply: Channel[Result[List[Jobs.Lease]]] = Channel.new(1)
      fetch = Jobs.Fetch(queue: "q", lease_ms: 1_000, max_per_group: 1)
      until = Parked.Until(ms: 100_000, real_ms: 100_000)
      first = Parked.park(Parked.empty(), fetch, until, reply)
      both = Parked.park(first, fetch, until, reply)
      try Test.eq(Parked.next_look(both), none)
      late = Parked.look(both, both.waiters[1], Parked.Looked(changes: 1, until_ms: some(900)))
      soon = Parked.look(late, late.waiters[2], Parked.Looked(changes: 1, until_ms: some(300)))
      try Test.eq(Parked.next_look(soon), some(300))
      passed = Parked.expired(soon, 300, 0).parked
      try Test.eq(Parked.next_look(passed), some(900))
      return Test.eq(Parked.next_look(Parked.expired(passed, 900, 0).parked), none)
    end,
  ])
end

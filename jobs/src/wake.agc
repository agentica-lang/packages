## When the actor of the memory backend wakes by itself, as a pure choice of the store and the parked fetches: how long
## until something may change for a parked fetch. A job that is due already and still waits is held by a limit per
## group: only the end of a lease frees it, and that is a time here.

import Parked from "parked"
import Store from "store"

## The longest the actor sleeps while a fetch waits, so a clock that is set by hand, or that jumps, is seen.
CAP_MS = 100

## In how many ms to wake: the first job that is not due, the first lease to expire, the first time a held fetch looks
## again, or the first deadline, but not after `CAP_MS` and not before 1. None when no fetch waits.
def in_ms(store: Store.Store, parked: Parked.Parked, now: Int, real_now: Int) -> Optional[Int]
  return none if Parked.empty?(parked)

  times: List[Int] = []
  for queue in Parked.queues(parked)
    case Store.next_job_at(store, queue, now)
      some(at) -> times = times.push(at)
      none -> nil
    end
  end

  case Store.next_expiry(store)
    some(at) -> times = times.push(at)
    none -> nil
  end

  case Parked.next_look(parked)
    some(at) -> times = times.push(at)
    none -> nil
  end

  case Parked.next_wait(parked, now, real_now)
    some(ms) -> times = times.push(now + ms)
    none -> nil
  end

  case times.min
    some(at) -> some((at - now).clamp(1, CAP_MS))
    none -> none
  end
end

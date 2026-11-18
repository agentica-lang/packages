## The fetches that wait for jobs, kept so that a call costs in proportion to what it touches, not to how many fetches
## wait: the waiters by number, the numbers of each queue in the order the fetches came, and the deadlines in order. A
## waiter has two deadlines, the first of them ends it: one on the clock of the backend and one on the real clock, so a
## clock that nobody moves does not keep a fetch past its `wait_ms`. A waiter that left (served, or its time is up) is
## dropped from `waiters` at once; its number stays in the heaps until it comes to the front there, where it is
## skipped.

import Heap from "std/heap"
import Types from "types"

## A fetch that waits: until when (on the clock of the backend, and on the real one) and where to answer. `looked` is
## what it saw when a limit per group held every job back, so that it looks again only when that can have changed.
struct Waiter
  seq: Int
  fetch: Types.Fetch
  until_ms: Int
  real_until_ms: Int
  reply: Channel[Result[List[Types.Lease]]]
  looked: Optional[Looked]
end

## The count of changes of the store (a job that waits, a lease that ended) and the time when a job that was not due
## comes due (none when there is no such job).
struct Looked
  changes: Int
  until_ms: Optional[Int]
end

struct Mark
  at_ms: Int
  seq: Int
end

struct Parked
  waiters: Map[Int, Waiter]
  queues: Map[String, Heap.Heap[Int]]
  deadlines: Heap.Heap[Mark]
  real_deadlines: Heap.Heap[Mark]
  looks: Heap.Heap[Mark]
  next_seq: Int
end

## The oldest waiter of a queue, and the waiters with the stale numbers dropped.
struct Front
  parked: Parked
  waiter: Optional[Waiter]
end

## The two deadlines of a waiter, on the clock of the backend and on the real one.
struct Until
  ms: Int
  real_ms: Int
end

## The waiters whose time is up.
struct Expired
  parked: Parked
  waiters: List[Waiter]
end

def empty() -> Parked
  Parked(
    waiters: {},
    queues: {},
    deadlines: Heap.new(&marks_first),
    real_deadlines: Heap.new(&marks_first),
    looks: Heap.new(&marks_first),
    next_seq: 1,
  )
end

## Adds a fetch that waits.
def park(parked: Parked, fetch: Types.Fetch, until: Until, reply: Channel[Result[List[Types.Lease]]]) -> Parked
  seq = parked.next_seq
  waiter = Waiter(seq: seq, fetch: fetch, until_ms: until.ms, real_until_ms: until.real_ms, reply: reply, looked: none)
  line = parked.queues.get(fetch.queue, Heap.new(&ints_first))
  parked.with(
    waiters: parked.waiters.put(seq, waiter),
    queues: parked.queues.put(fetch.queue, Heap.push(line, seq)),
    deadlines: Heap.push(parked.deadlines, Mark(at_ms: until.ms, seq: seq)),
    real_deadlines: Heap.push(parked.real_deadlines, Mark(at_ms: until.real_ms, seq: seq)),
    next_seq: seq + 1,
  )
end

## The queues that have waiters, or had until a number was dropped.
def queues(parked: Parked) -> List[String] = parked.queues.keys

def front(parked: Parked, queue: String) -> Front
  state = parked
  while true
    case first_number(state, queue)
      some(seq) ->
        case state.waiters.get(seq)
          some(waiter) -> return Front(parked: state, waiter: some(waiter))
          none -> state = drop_number(state, queue)
        end

      none -> return Front(parked: state, waiter: none)
    end
  end

  Front(parked: state, waiter: none)
end

## The waiters of a queue, oldest first. It costs the waiters of all queues, so it is for the rare case of a waiter
## that a limit per group holds back, and not for each call.
def line(parked: Parked, queue: String) -> List[Waiter]
  parked.waiters.values.select(->(waiter) { waiter.fetch.queue == queue }).sort_by(->(waiter) { waiter.seq })
end

## What the waiter saw when a limit held every job back.
def look(parked: Parked, waiter: Waiter, looked: Looked) -> Parked
  state = parked.with(waiters: parked.waiters.put(waiter.seq, waiter.with(looked: some(looked))))
  case looked.until_ms
    some(at) if not same_time?(waiter, at) ->
      state.with(looks: Heap.push(state.looks, Mark(at_ms: at, seq: waiter.seq)))
    _ -> state
  end
end

## When the first job that a waiter saw as not due comes due: the backend wakes then, and not at its cap. A waiter that
## is gone leaves its time until it passes, which is one wake for nothing.
def next_look(parked: Parked) -> Optional[Int]
  case Heap.peek(parked.looks)
    ok(mark) -> some(mark.at_ms)
    error(_) -> none
  end
end

## Whether the waiter saw this store (its count of changes) and no job has come due since.
def looked_at?(waiter: Waiter, changes: Int, now: Int) -> Bool
  case waiter.looked
    some(looked) ->
      case looked.until_ms
        some(at) -> looked.changes == changes and now < at
        none -> looked.changes == changes
      end

    none -> false
  end
end

## The waiter leaves.
def remove(parked: Parked, seq: Int) -> Parked = parked.with(waiters: parked.waiters.delete(seq))

## Takes out the waiters whose deadline is `now` (the clock of the backend) or `real_now` (the real one), or before.
def expired(parked: Parked, now: Int, real_now: Int) -> Expired
  by_clock = draw(parked.deadlines, now)
  by_real = draw(parked.real_deadlines, real_now)
  state = parked.with(deadlines: by_clock.heap, real_deadlines: by_real.heap, looks: draw(parked.looks, now).heap)
  out: List[Waiter] = []
  for seq in by_clock.seqs + by_real.seqs
    case state.waiters.get(seq)
      some(waiter) ->
        state = remove(state, seq)
        out = out.push(waiter)
      none -> nil
    end
  end

  Expired(parked: state, waiters: out)
end

## In how many ms the first deadline comes, on either clock.
def next_wait(parked: Parked, now: Int, real_now: Int) -> Optional[Int]
  waits: List[Int] = []
  case left(parked.deadlines, now)
    some(ms) -> waits = waits.push(ms)
    none -> nil
  end

  case left(parked.real_deadlines, real_now)
    some(ms) -> waits = waits.push(ms)
    none -> nil
  end

  waits.min
end

def all(parked: Parked) -> List[Waiter] = parked.waiters.values

def empty?(parked: Parked) -> Bool = parked.waiters.empty?

private

struct Drawn
  heap: Heap.Heap[Mark]
  seqs: List[Int]
end

# Whether the waiter already has a mark for that time.
def same_time?(waiter: Waiter, at: Int) -> Bool
  case waiter.looked
    some(looked) -> looked.until_ms == some(at)
    none -> false
  end
end

def marks_first(a: Mark, b: Mark) -> Bool = a.at_ms < b.at_ms

def ints_first(a: Int, b: Int) -> Bool = a < b

# The marks that are due at `limit`, taken out of the heap.
def draw(heap: Heap.Heap[Mark], limit: Int) -> Drawn
  rest = heap
  seqs: List[Int] = []
  while due?(rest, limit)
    # `due?` found the heap not empty.
    popped = Heap.pop(rest).unwrap!
    rest = popped.remaining
    seqs = seqs.push(popped.value.seq)
  end

  Drawn(heap: rest, seqs: seqs)
end

def due?(heap: Heap.Heap[Mark], limit: Int) -> Bool
  case Heap.peek(heap)
    ok(mark) -> mark.at_ms <= limit
    error(_) -> false
  end
end

def left(heap: Heap.Heap[Mark], now: Int) -> Optional[Int]
  case Heap.peek(heap)
    ok(mark) -> some(mark.at_ms - now)
    error(_) -> none
  end
end

def first_number(parked: Parked, queue: String) -> Optional[Int]
  case parked.queues.get(queue)
    some(line) ->
      case Heap.peek(line)
        ok(seq) -> some(seq)
        error(_) -> none
      end

    none -> none
  end
end

# The number at the front is stale: drop it, and the queue itself when it was the last.
def drop_number(parked: Parked, queue: String) -> Parked
  # The caller saw a number at the front, so the queue and its heap are there.
  popped = Heap.pop(parked.queues[queue]).unwrap!
  return parked.with(queues: parked.queues.delete(queue)) if Heap.empty?(popped.remaining)

  parked.with(queues: parked.queues.put(queue, popped.remaining))
end

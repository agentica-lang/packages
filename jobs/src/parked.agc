## The fetches that wait for jobs, kept so that a call costs in proportion to what it touches, not to how many fetches
## wait: the waiters by number, the numbers of each queue in the order the fetches came, and the deadlines in order. A
## waiter that left (served, or its time is up) is dropped from `waiters` at once; its number stays in the heaps until
## it comes to the front there, where it is skipped.

import Heap from "std/heap"
import Types from "types"

## A fetch that waits: until when (on the clock of the backend) and where to answer.
struct Waiter
  seq: Int
  fetch: Types.Fetch
  until_ms: Int
  reply: Channel[Result[List[Types.Lease]]]
end

struct Mark
  at_ms: Int
  seq: Int
end

struct Parked
  waiters: Map[Int, Waiter]
  queues: Map[String, Heap.Heap[Int]]
  deadlines: Heap.Heap[Mark]
  next_seq: Int
end

## The oldest waiter of a queue, and the waiters with the stale numbers dropped.
struct Front
  parked: Parked
  waiter: Optional[Waiter]
end

## The waiters whose time is up.
struct Expired
  parked: Parked
  waiters: List[Waiter]
end

def empty() -> Parked = Parked(waiters: {}, queues: {}, deadlines: Heap.new(&marks_first), next_seq: 1)

## Adds a fetch that waits.
def park(parked: Parked, fetch: Types.Fetch, until_ms: Int, reply: Channel[Result[List[Types.Lease]]]) -> Parked
  seq = parked.next_seq
  waiter = Waiter(seq: seq, fetch: fetch, until_ms: until_ms, reply: reply)
  line = parked.queues.get(fetch.queue, Heap.new(&ints_first))
  Parked(
    waiters: parked.waiters.put(seq, waiter),
    queues: parked.queues.put(fetch.queue, Heap.push(line, seq)),
    deadlines: Heap.push(parked.deadlines, Mark(at_ms: until_ms, seq: seq)),
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

## The waiter leaves.
def remove(parked: Parked, seq: Int) -> Parked = parked.with(waiters: parked.waiters.delete(seq))

## Takes out the waiters whose deadline is `now` or before.
def expired(parked: Parked, now: Int) -> Expired
  state = parked
  out: List[Waiter] = []
  while due?(state, now)
    # `due?` found the heap not empty.
    popped = Heap.pop(state.deadlines).unwrap!
    state = state.with(deadlines: popped.remaining)
    case state.waiters.get(popped.value.seq)
      some(waiter) ->
        state = remove(state, waiter.seq)
        out = out.push(waiter)
      none -> nil
    end
  end

  Expired(parked: state, waiters: out)
end

## The first deadline that is still ahead.
def next_deadline(parked: Parked) -> Optional[Int]
  case Heap.peek(parked.deadlines)
    ok(mark) -> some(mark.at_ms)
    error(_) -> none
  end
end

def all(parked: Parked) -> List[Waiter] = parked.waiters.values

def empty?(parked: Parked) -> Bool = parked.waiters.empty?

private

def marks_first(a: Mark, b: Mark) -> Bool = a.at_ms < b.at_ms

def ints_first(a: Int, b: Int) -> Bool = a < b

def due?(parked: Parked, now: Int) -> Bool
  case Heap.peek(parked.deadlines)
    ok(mark) -> mark.at_ms <= now
    error(_) -> false
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

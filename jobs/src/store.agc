## The jobs of the memory backend and the rules they follow, as plain values: every function takes the store and the
## time and gives a new store, so the actor of `memory.agc` is the only owner and nothing here sleeps or reads a clock.
##
## A live job is waiting (in the heap of its queue, ordered by `run_at_ms`, then by insertion) or leased (with an entry
## in the heap of expiries). The heap of expiries is not cleaned when a lease ends: an entry whose lease is gone or
## moved is skipped when it comes up.

import Heap from "std/heap"
import Types from "types"

## A lease that `ack`, `nack` or `extend` found to be live; the entry of a job that is not live gives none.
struct Held
  token: String
  expires_at_ms: Int
end

struct Entry
  job: Types.Job
  ord: Int
  lease: Optional[Held]
end

struct Store
  max_jobs: Int
  max_dead: Int
  entries: Map[String, Entry]
  waiting: Map[String, Heap.Heap[Slot]]
  expiries: Heap.Heap[Expiry]
  keys: Map[String, String]
  dead: List[Entry]
  next_ord: Int
  next_token: Int
end

## A store and what an operation gave.
struct Added
  store: Store
  enqueued: List[Types.Enqueued]
end

struct Taken
  store: Store
  leases: List[Types.Lease]
end

struct Extended
  store: Store
  lease: Types.Lease
end

struct Slot
  run_at_ms: Int
  ord: Int
  id: String
end

struct Expiry
  at_ms: Int
  id: String
  token: String
end

struct Leased
  store: Store
  lease: Types.Lease
end

## An empty store.
def empty(max_jobs: Int, max_dead: Int) -> Store
  Store(
    max_jobs: max_jobs,
    max_dead: max_dead,
    entries: {},
    waiting: {},
    expiries: Heap.new(&expires_first),
    keys: {},
    dead: [],
    next_ord: 1,
    next_token: 1,
  )
end

## Applies the time: a lease that ran out gives its job back, or makes it dead when it was the last attempt.
def tick(store: Store, now: Int) -> Store
  state = store
  while expired?(state, now)
    # `expired?` found the heap not empty, so `pop` cannot fail.
    popped = Heap.pop(state.expiries).unwrap!
    state = expire(state.with(expiries: popped.remaining), popped.value)
  end

  state
end

## When something waits for the clock: the first job due in `queue`, or the first lease to expire, whichever is first.
def next_due(store: Store, queue: String) -> Optional[Int]
  times: List[Int] = []
  case Heap.peek(store.waiting.get(queue, Heap.new(&starts_first)))
    ok(slot) -> times = times.push(slot.run_at_ms)
    error(_) -> nil
  end

  case Heap.peek(store.expiries)
    ok(expiry) -> times = times.push(expiry.at_ms)
    error(_) -> nil
  end

  times.min
end

## Adds the jobs, or none of them: one that is not valid, or one that does not fit, fails the call.
def enqueue(store: Store, now: Int, jobs: List[Types.NewJob]) -> Result[Added]
  state = store
  enqueued: List[Types.Enqueued] = []
  for new in jobs
    try valid(new)
    added = try add(state, now, new)
    state = added.store
    enqueued = enqueued.push(added.enqueued[0])
  end

  ok(Added(store: state, enqueued: enqueued))
end

## Leases up to `fetch.max` of the jobs of the queue whose time has come, the first due first.
def take(store: Store, now: Int, fetch: Types.Fetch) -> Result[Taken]
  if fetch.max < 1 or fetch.lease_ms < 1
    return error("jobs error: fetch max and lease_ms must be at least 1", kind: "argument")
  end

  return error("jobs error: fetch wait_ms cannot be negative", kind: "argument") if fetch.wait_ms < 0

  state = store
  leases: List[Types.Lease] = []
  while leases.size < fetch.max
    case due_slot(state, fetch.queue, now)
      some(slot) ->
        leased = lease(pop_slot(state, fetch.queue), slot, now, fetch.lease_ms)
        state = leased.store
        leases = leases.push(leased.lease)
      none -> break
    end
  end

  ok(Taken(store: state, leases: leases))
end

## Puts back leases that nobody got (the caller gave up): the delivery does not count.
def untake(store: Store, leases: List[Types.Lease]) -> Store
  state = store
  for held in leases
    case live(state, held)
      some(entry) ->
        state = requeue(state, entry.with(job: entry.job.with(attempt: entry.job.attempt - 1)), entry.job.run_at_ms)
      none -> nil
    end
  end

  state
end

## Removes the job of a lease that is live.
def ack(store: Store, held: Types.Lease) -> Result[Store]
  entry = try owned(store, held)
  ok(finish(store, entry))
end

def nack(store: Store, held: Types.Lease, how: Types.Nack) -> Result[Store]
  entry = try owned(store, held)
  case how
    Types.Nack.Retry(_) if entry.job.attempt >= entry.job.max_attempts -> ok(kill(store, entry, "no attempts left"))
    Types.Nack.Retry(at_ms) -> ok(requeue(store, entry, at_ms))
    Types.Nack.Release ->
      ok(requeue(store, entry.with(job: entry.job.with(attempt: entry.job.attempt - 1)), entry.job.run_at_ms))
    Types.Nack.Dead(reason) -> ok(kill(store, entry, reason))
  end
end

def extend(store: Store, now: Int, held: Types.Lease, ms: Int) -> Result[Extended]
  return error("jobs error: extend needs at least 1 ms, got #{ms}", kind: "argument") if ms < 1

  entry = try owned(store, held)
  at_ms = now + ms
  renewed = Held(token: held.token, expires_at_ms: at_ms)
  state = store.with(
    entries: store.entries.put(entry.job.id, entry.with(lease: some(renewed))),
    expiries: Heap.push(store.expiries, Expiry(at_ms: at_ms, id: entry.job.id, token: held.token)),
  )

  ok(Extended(store: state, lease: held.with(job: entry.job, expires_at_ms: at_ms)))
end

def counts(store: Store, now: Int, queue: String) -> Types.Counts
  ready = 0
  scheduled = 0
  leased = 0
  for entry in store.entries.values
    if entry.job.queue == queue
      case entry.lease
        some(_) -> leased += 1
        none if entry.job.run_at_ms <= now -> ready += 1
        none -> scheduled += 1
      end
    end
  end

  dead = store.dead.filter(->(entry) { entry.job.queue == queue }).size
  Types.Counts(ready: ready, scheduled: scheduled, leased: leased, dead: dead)
end

private

def starts_first(a: Slot, b: Slot) -> Bool
  a.run_at_ms < b.run_at_ms or (a.run_at_ms == b.run_at_ms and a.ord < b.ord)
end

def expires_first(a: Expiry, b: Expiry) -> Bool = a.at_ms < b.at_ms

def expired?(store: Store, now: Int) -> Bool
  case Heap.peek(store.expiries)
    ok(expiry) -> expiry.at_ms <= now
    error(_) -> false
  end
end

# A key is the queue and the unique key, with the length of the queue so that two pairs never give the same text.
def key_of(queue: String, unique_key: String) -> String = "#{queue.size}:#{queue}:#{unique_key}"

def valid(new: Types.NewJob) -> Result[Void]
  return error("jobs error: queue cannot be empty", kind: "argument") if new.queue == ""

  if new.max_attempts < 1
    return error("jobs error: max_attempts must be at least 1, got #{new.max_attempts}", kind: "argument")
  end

  return error("jobs error: run_at_ms cannot be negative, got #{new.run_at_ms}", kind: "argument") if new.run_at_ms < 0

  case new.unique_key
    some("") -> error("jobs error: unique_key cannot be empty", kind: "argument")
    _ -> ok()
  end
end

def add(store: Store, now: Int, new: Types.NewJob) -> Result[Added]
  case duplicate_of(store, new)
    some(id) -> ok(Added(store: store, enqueued: [Types.Enqueued(id: id, duplicate: true)]))
    none if store.entries.size >= store.max_jobs ->
      error("jobs error: the queue is full (max_jobs #{store.max_jobs})", kind: "jobs.full")
    none -> ok(insert(store, now, new))
  end
end

def duplicate_of(store: Store, new: Types.NewJob) -> Optional[String]
  case new.unique_key
    some(key) -> store.keys.get(key_of(new.queue, key))
    none -> none
  end
end

# 0 asks for now.
def due_at(run_at_ms: Int, now: Int) -> Int
  return now if run_at_ms == 0

  run_at_ms
end

def insert(store: Store, now: Int, new: Types.NewJob) -> Added
  ord = store.next_ord
  id = "#{ord}"
  run_at_ms = due_at(new.run_at_ms, now)
  job = Types.Job(
    id: id,
    queue: new.queue,
    payload: new.payload,
    attempt: 0,
    max_attempts: new.max_attempts,
    run_at_ms: run_at_ms,
    inserted_at_ms: now,
    unique_key: new.unique_key,
    meta: new.meta,
    last_error: none,
  )

  keys = case new.unique_key
    some(key) -> store.keys.put(key_of(new.queue, key), id)
    none -> store.keys
  end

  state = store.with(
    entries: store.entries.put(id, Entry(job: job, ord: ord, lease: none)),
    keys: keys,
    next_ord: ord + 1,
  )

  Added(
    store: push_slot(state, Entry(job: job, ord: ord, lease: none)),
    enqueued: [Types.Enqueued(id: id, duplicate: false)],
  )
end

def push_slot(store: Store, entry: Entry) -> Store
  slot = Slot(run_at_ms: entry.job.run_at_ms, ord: entry.ord, id: entry.job.id)
  heap = store.waiting.get(entry.job.queue, Heap.new(&starts_first))
  store.with(waiting: store.waiting.put(entry.job.queue, Heap.push(heap, slot)))
end

def due_slot(store: Store, queue: String, now: Int) -> Optional[Slot]
  case store.waiting.get(queue)
    some(heap) ->
      case Heap.peek(heap)
        ok(slot) if slot.run_at_ms <= now -> some(slot)
        _ -> none
      end

    none -> none
  end
end

def pop_slot(store: Store, queue: String) -> Store
  # The caller saw a slot in this heap, so it is not empty.
  popped = Heap.pop(store.waiting[queue]).unwrap!
  store.with(waiting: store.waiting.put(queue, popped.remaining))
end

def lease(store: Store, slot: Slot, now: Int, lease_ms: Int) -> Leased
  # A slot is in the heap only while its job waits, so the job is in `entries`.
  entry = store.entries[slot.id]
  token = "t#{store.next_token}"
  at_ms = now + lease_ms
  job = entry.job.with(attempt: entry.job.attempt + 1)
  held = Entry(job: job, ord: entry.ord, lease: some(Held(token: token, expires_at_ms: at_ms)))
  state = store.with(
    entries: store.entries.put(job.id, held),
    expiries: Heap.push(store.expiries, Expiry(at_ms: at_ms, id: job.id, token: token)),
    next_token: store.next_token + 1,
  )

  Leased(store: state, lease: Types.Lease(job: job, token: token, expires_at_ms: at_ms))
end

# The entry whose live lease is this one.
def live(store: Store, held: Types.Lease) -> Optional[Entry]
  case store.entries.get(held.job.id)
    some(entry) ->
      case entry.lease
        some(current) if current.token == held.token -> some(entry)
        _ -> none
      end

    none -> none
  end
end

def owned(store: Store, held: Types.Lease) -> Result[Entry]
  case live(store, held)
    some(entry) -> ok(entry)
    none -> error("jobs error: the lease of job #{held.job.id} is lost", kind: "jobs.lease_lost")
  end
end

# The job leaves the store for good (acked), and its unique key is free.
def finish(store: Store, entry: Entry) -> Store
  keys = case entry.job.unique_key
    some(key) -> store.keys.delete(key_of(entry.job.queue, key))
    none -> store.keys
  end

  store.with(entries: store.entries.delete(entry.job.id), keys: keys)
end

def kill(store: Store, entry: Entry, reason: String) -> Store
  gone = finish(store, entry)
  buried = gone.dead.push(entry.with(job: entry.job.with(last_error: some(reason)), lease: none))
  gone.with(dead: buried.drop((buried.size - store.max_dead).clamp(0, buried.size)))
end

def requeue(store: Store, entry: Entry, run_at_ms: Int) -> Store
  waiting = Entry(job: entry.job.with(run_at_ms: run_at_ms), ord: entry.ord, lease: none)
  push_slot(store.with(entries: store.entries.put(entry.job.id, waiting)), waiting)
end

# The lease of this expiry, when it is still the live one of its job.
def expire(store: Store, expiry: Expiry) -> Store
  case store.entries.get(expiry.id)
    some(entry) ->
      case entry.lease
        some(held) if held.token == expiry.token and held.expires_at_ms == expiry.at_ms -> lost(store, entry)
        _ -> store
      end

    none -> store
  end
end

def lost(store: Store, entry: Entry) -> Store
  if entry.job.attempt >= entry.job.max_attempts
    kill(store, entry, "the lease expired on the last attempt")
  else
    requeue(store, entry, entry.job.run_at_ms)
  end
end

## The jobs of the memory backend and the rules they follow, as plain values: every function takes the store and the
## time and gives a new store, so the actor of `memory.agc` is the only owner and nothing here sleeps or reads a clock.
##
## A live job is waiting or leased (with an entry in the heap of expiries). The heap of expiries is not cleaned when a
## lease ends: an entry whose lease is gone or moved is skipped when it comes up.
##
## The waiting jobs of a queue are `Ready` (ordered by `run_at_ms`, then by insertion): a heap for the jobs with no
## group, a heap for each group, and a heap of the first slot of each group. A fetch takes the first of the plain heap
## and of the heads, and a head of a full group is set aside, so it passes over a group in one step, however many jobs
## the group holds. `groups` counts the live leases of each group of a queue, kept in step by every function that
## starts or ends a lease (`lease`, `finish`, `requeue`).

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
  waiting: Map[String, Ready]
  expiries: Heap.Heap[Expiry]
  keys: Map[String, String]
  groups: Map[String, Int]
  dead: List[Entry]
  next_ord: Int
  next_token: Int
  changes: Int
end

## A store and what an operation gave.
struct Added
  store: Store
  enqueued: List[Types.Enqueued]
end

## What a fetch took. `held_back` is whether it passed over a group that was full, `later_at_ms` when the first job
## that is not due comes due, and `visits` how many slots and heads it looked at, which does not grow with the jobs of
## a full group.
struct Taken
  store: Store
  leases: List[Types.Lease]
  held_back: Bool
  later_at_ms: Optional[Int]
  visits: Int
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

## The first slot of a group, and the group. A head is current while it is the first slot of its group; one that is not
## is dropped when it comes to the front.
struct Head
  slot: Slot
  group: String
end

## The waiting jobs of a queue.
struct Ready
  plain: Heap.Heap[Slot]
  groups: Map[String, Heap.Heap[Slot]]
  heads: Heap.Heap[Head]
end

## The slot that a fetch takes, and its group when it came from a group.
struct Found
  slot: Slot
  group: Optional[String]
end

## The store, the heads that a fetch set aside (full groups), what it found and how many slots and heads it looked at.
struct Seen
  store: Store
  set_aside: List[Head]
  found: Optional[Found]
  visits: Int
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
    groups: {},
    dead: [],
    next_ord: 1,
    next_token: 1,
    changes: 0,
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

## When the next waiting job of `queue` that is not due yet comes due. A job that is due and waits is held by a limit
## per group, and only the end of a lease frees it, so it has no time here.
def next_job_at(store: Store, queue: String, now: Int) -> Optional[Int]
  ready = ready_of(store, queue)
  times: List[Int] = []
  case Heap.peek(ready.plain)
    ok(slot) if slot.run_at_ms > now -> times = times.push(slot.run_at_ms)
    _ -> nil
  end

  case Heap.peek(ready.heads)
    ok(head) if head.slot.run_at_ms > now -> times = times.push(head.slot.run_at_ms)
    _ -> nil
  end

  times.min
end

## When the first lease expires.
def next_expiry(store: Store) -> Optional[Int]
  case Heap.peek(store.expiries)
    ok(expiry) -> some(expiry.at_ms)
    error(_) -> none
  end
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

## Leases up to `fetch.max` of the jobs of the queue whose time has come, the first due first. A job whose group has
## `fetch.max_per_group` live leases is left where it is, and the next one is taken; the leases of this call count.
def take(store: Store, now: Int, fetch: Types.Fetch) -> Result[Taken]
  if fetch.max < 1 or fetch.lease_ms < 1
    return error("jobs error: fetch max and lease_ms must be at least 1", kind: "argument")
  end

  return error("jobs error: fetch wait_ms cannot be negative", kind: "argument") if fetch.wait_ms < 0

  if fetch.max_per_group < 0
    return error("jobs error: fetch max_per_group cannot be negative, got #{fetch.max_per_group}", kind: "argument")
  end

  state = store
  leases: List[Types.Lease] = []
  set_aside: List[Head] = []
  visits = 0
  while leases.size < fetch.max
    seen = first_ready(state, fetch.queue, now, fetch.max_per_group, set_aside)
    state = seen.store
    set_aside = seen.set_aside
    visits += seen.visits
    case seen.found
      some(found) ->
        leased = lease(take_slot(state, fetch.queue, found), found.slot, now, fetch.lease_ms)
        state = leased.store
        leases = leases.push(leased.lease)
      none -> break
    end
  end

  ok(
    Taken(
      store: put_back(state, fetch.queue, set_aside),
      leases: leases,
      held_back: not set_aside.empty?,
      later_at_ms: next_job_at(state, fetch.queue, now),
      visits: visits,
    ),
  )
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
    Types.Nack.Retry(later) if entry.job.attempt >= entry.job.max_attempts ->
      ok(kill(store, entry, later.error.unwrap_or("no attempts left")))
    Types.Nack.Retry(later) -> ok(requeue(store, failed(entry, later.error), later.at_ms))
    Types.Nack.Release ->
      ok(requeue(store, entry.with(job: entry.job.with(attempt: entry.job.attempt - 1)), entry.job.run_at_ms))
    Types.Nack.Dead(message) -> ok(kill(store, entry, message))
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

def heads_first(a: Head, b: Head) -> Bool = starts_first(a.slot, b.slot)

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

  case new.group
    some("") -> return error("jobs error: group cannot be empty", kind: "argument")
    _ -> nil
  end

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
    group: new.group,
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

def ready_of(store: Store, queue: String) -> Ready
  store.waiting.get(queue, Ready(plain: Heap.new(&starts_first), groups: {}, heads: Heap.new(&heads_first)))
end

# A job that waits, or a lease that ended, is what can give a fetch that found nothing its job: `changes` counts both.
def push_slot(store: Store, entry: Entry) -> Store
  slot = Slot(run_at_ms: entry.job.run_at_ms, ord: entry.ord, id: entry.job.id)
  ready = ready_of(store, entry.job.queue)
  changed = store.with(changes: store.changes + 1)
  case entry.job.group
    some(group) -> changed.with(waiting: store.waiting.put(entry.job.queue, push_grouped(ready, slot, group)))
    none ->
      plain = Ready(plain: Heap.push(ready.plain, slot), groups: ready.groups, heads: ready.heads)
      changed.with(waiting: store.waiting.put(entry.job.queue, plain))
  end
end

# The slot goes in the heap of its group, and it is a head when it comes before the one that is there.
def push_grouped(ready: Ready, slot: Slot, group: String) -> Ready
  line = ready.groups.get(group, Heap.new(&starts_first))
  first_slot = Heap.peek(line)
  heads = case first_slot
    ok(first) if starts_first(first, slot) -> ready.heads
    _ -> Heap.push(ready.heads, Head(slot: slot, group: group))
  end

  Ready(plain: ready.plain, groups: ready.groups.put(group, Heap.push(line, slot)), heads: heads)
end

# The first waiting job that is due and that a limit does not hold back. The head of a full group is taken out of
# its heap and set aside, and a head that is not current is dropped.
def first_ready(store: Store, queue: String, now: Int, limit: Int, set_aside: List[Head]) -> Seen
  state = store
  aside = set_aside
  visits = 0
  while true
    visits += 1
    ready = ready_of(state, queue)
    plain = Heap.peek(ready.plain)
    case Heap.peek(ready.heads)
      ok(head) if not current?(ready, head) -> state = drop_head(state, queue)
      ok(head) if head_first?(head, plain) and head.slot.run_at_ms > now -> break
      ok(head) if head_first?(head, plain) and full?(state, queue, head.group, limit) ->
        state = drop_head(state, queue)
        aside = aside.push(head)
      ok(head) if head_first?(head, plain) ->
        return Seen(
          store: state,
          set_aside: aside,
          found: some(Found(slot: head.slot, group: some(head.group))),
          visits: visits,
        )
      _ ->
        case plain
          ok(slot) if slot.run_at_ms <= now ->
            return Seen(store: state, set_aside: aside, found: some(Found(slot: slot, group: none)), visits: visits)
          _ -> break
        end
    end
  end

  Seen(store: state, set_aside: aside, found: none, visits: visits)
end

# Whether the head comes before the first of the plain heap.
def head_first?(head: Head, plain: Result[Slot]) -> Bool
  case plain
    ok(slot) -> starts_first(head.slot, slot)
    error(_) -> true
  end
end

def current?(ready: Ready, head: Head) -> Bool
  case ready.groups.get(head.group)
    some(line) ->
      case Heap.peek(line)
        ok(first) -> first == head.slot
        error(_) -> false
      end

    none -> false
  end
end

def drop_head(store: Store, queue: String) -> Store
  ready = ready_of(store, queue)
  # The caller saw a head in this heap, so it is not empty.
  popped = Heap.pop(ready.heads).unwrap!
  store.with(
    waiting: store.waiting.put(queue, Ready(plain: ready.plain, groups: ready.groups, heads: popped.remaining)),
  )
end

# The slot leaves the heap that it was found in. A group has its next slot as the head, and no heap when it is empty.
def take_slot(store: Store, queue: String, found: Found) -> Store
  ready = ready_of(store, queue)
  case found.group
    some(group) ->
      state = drop_head(store, queue)
      store_of(state, queue, without_first(ready_of(state, queue), group))
    none ->
      # The caller saw a slot in this heap, so it is not empty.
      popped = Heap.pop(ready.plain).unwrap!
      store_of(store, queue, Ready(plain: popped.remaining, groups: ready.groups, heads: ready.heads))
  end
end

def store_of(store: Store, queue: String, ready: Ready) -> Store = store.with(waiting: store.waiting.put(queue, ready))

def without_first(ready: Ready, group: String) -> Ready
  # The group had a slot, and it is the one that was found.
  popped = Heap.pop(ready.groups[group]).unwrap!
  if Heap.empty?(popped.remaining)
    return Ready(plain: ready.plain, groups: ready.groups.delete(group), heads: ready.heads)
  end

  # The group goes on with its next slot, which is a head now.
  next_slot = Heap.peek(popped.remaining).unwrap!
  Ready(
    plain: ready.plain,
    groups: ready.groups.put(group, popped.remaining),
    heads: Heap.push(ready.heads, Head(slot: next_slot, group: group)),
  )
end

# Whether the group already has `limit` live leases; no limit is never full.
def full?(store: Store, queue: String, group: String, limit: Int) -> Bool
  limit > 0 and store.groups.get(key_of(queue, group), 0) >= limit
end

# The heads that a fetch set aside go back, and the heads that are not current leave the front.
def put_back(store: Store, queue: String, heads: List[Head]) -> Store
  ready = ready_of(store, queue)
  pushed = heads.reduce(ready.heads, ->(all, head) { Heap.push(all, head) })
  cleaned = Ready(plain: ready.plain, groups: ready.groups, heads: pushed)
  store_of(store, queue, drop_stale(cleaned))
end

def drop_stale(ready: Ready) -> Ready
  heads = ready.heads
  while true
    case Heap.peek(heads)
      ok(head) if not current?(ready, head) -> heads = Heap.pop(heads).unwrap!.remaining
      _ -> break
    end
  end

  Ready(plain: ready.plain, groups: ready.groups, heads: heads)
end

# The group of a job has one more live lease, or one less.
def count_group(store: Store, job: Types.Job, change: Int) -> Store
  case job.group
    some(group) ->
      freed = note_freed(store, change)
      freed.with(groups: counted(store.groups, key_of(job.queue, group), change))
    none -> store
  end
end

# A lease that ends can free a job that a limit held back.
def note_freed(store: Store, change: Int) -> Store
  return store.with(changes: store.changes + 1) if change < 0

  store
end

# A count that falls to 0 leaves the map, so the map holds the groups that have a lease.
def counted(groups: Map[String, Int], key: String, change: Int) -> Map[String, Int]
  count = groups.get(key, 0) + change
  return groups.delete(key) if count <= 0

  groups.put(key, count)
end

def lease(store: Store, slot: Slot, now: Int, lease_ms: Int) -> Leased
  # A slot is in the heap only while its job waits, so the job is in `entries`.
  entry = store.entries[slot.id]
  token = "t#{store.next_token}"
  at_ms = now + lease_ms
  job = entry.job.with(attempt: entry.job.attempt + 1)
  held = Entry(job: job, ord: entry.ord, lease: some(Held(token: token, expires_at_ms: at_ms)))
  state = count_group(
    store.with(
      entries: store.entries.put(job.id, held),
      expiries: Heap.push(store.expiries, Expiry(at_ms: at_ms, id: job.id, token: token)),
      next_token: store.next_token + 1,
    ),
    job,
    1,
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

  count_group(store.with(entries: store.entries.delete(entry.job.id), keys: keys), entry.job, -1)
end

def kill(store: Store, entry: Entry, message: String) -> Store
  gone = finish(store, entry)
  buried = gone.dead.push(entry.with(job: entry.job.with(last_error: some(message)), lease: none))
  gone.with(dead: buried.drop((buried.size - store.max_dead).clamp(0, buried.size)))
end

# A failed delivery keeps what went wrong, for the next one; a retry that says nothing leaves the last error.
def failed(entry: Entry, message: Optional[String]) -> Entry
  case message
    some(_) -> entry.with(job: entry.job.with(last_error: message))
    none -> entry
  end
end

def requeue(store: Store, entry: Entry, run_at_ms: Int) -> Store
  waiting = Entry(job: entry.job.with(run_at_ms: run_at_ms), ord: entry.ord, lease: none)
  push_slot(count_group(store.with(entries: store.entries.put(entry.job.id, waiting)), entry.job, -1), waiting)
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

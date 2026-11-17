## The memory backend: one `std/actor` actor owns a `Store` (store.agc) and takes the calls one at a time. Every call
## first applies the clock to the store, so a lease that ran out is back before the call is served, and a test with a
## manual clock needs no sleep.
##
## A fetch that waits for jobs is parked in the state of the actor, with its reply channel. The actor serves it when a
## job comes or is due, and ends it at its deadline; while one is parked the actor also wakes at least every
## WAKE_CAP_MS, so a clock that is set by hand, or that jumps, is seen. A caller that gave up while it waited makes
## `Actor.reply` give `false`, and the jobs go back to their queue.
##
## The actor is a child of the task that calls `start`: make the backend in `main`.

import Actor from "std/actor"
import Store from "store"
import Types from "types"

## A memory backend, or the error of a bad option.
def start(options: Types.MemoryOptions) -> Result[Types.Backend]
  try check(options)
  clock = options.clock.unwrap_or(&Time.now_ms)
  behaviour: Actor.Behaviour[State, Msg] = Actor.Behaviour(
    init: -> { State(store: Store.empty(options.max_jobs, options.max_dead), parked: [], clock: clock) },
    handle: &handle,
    terminate: some(&shutdown),
    timeout: some(Actor.Timeout(after_ms: &wake_in, handle: &wake)),
  )

  actor = Actor.start(behaviour, Actor.Options(capacity: INBOX))
  closed: ATS[String, Int] = ATS.new()
  ok(backend(Link(ref: actor, address: actor.address, closed: closed)))
end

private

# Room for the calls of many consumers at once: a call that finds the inbox full gives `jobs.timeout`.
INBOX = 4_096
# How long a caller waits for the actor to answer, besides the `wait_ms` of a fetch.
CALL_MS = 10_000
MAX_WAIT_MS = 86_400_000
WAKE_CAP_MS = 100
CLOSED = "closed"

enum Msg
  Enqueue(List[Types.NewJob], Channel[Result[List[Types.Enqueued]]])
  Fetch(Types.Fetch, Channel[Result[List[Types.Lease]]])
  Ack(Types.Lease, Channel[Result[Void]])
  Nack(Types.Lease, Types.Nack, Channel[Result[Void]])
  Extend(Types.Lease, Int, Channel[Result[Types.Lease]])
  Counts(String, Channel[Result[Types.Counts]])
end

# A fetch that waits: until when (on the clock of the backend) and where to answer.
struct Waiter
  fetch: Types.Fetch
  until_ms: Int
  reply: Channel[Result[List[Types.Lease]]]
end

struct State
  store: Store.Store
  parked: List[Waiter]
  clock: Fn[Int]
end

# What the functions of the backend share: the actor, and whether `close` ran.
struct Link
  ref: Actor.Ref[State, Msg]
  address: Address[Msg]
  closed: ATS[String, Int]
end

def check(options: Types.MemoryOptions) -> Result[Void]
  if options.max_jobs < 1
    return error("jobs error: max_jobs must be at least 1, got #{options.max_jobs}", kind: "argument")
  end

  if options.max_dead < 0
    return error("jobs error: max_dead cannot be negative, got #{options.max_dead}", kind: "argument")
  end

  ok()
end

def backend(link: Link) -> Types.Backend
  Types.Backend(
    name: "memory",
    caps: Types.Caps(),
    enqueue: ->(jobs) { ask(link, CALL_MS) do |reply| Msg.Enqueue(jobs, reply) end },
    fetch: ->(fetch) { fetch_jobs(link, fetch) },
    ack: ->(lease) { ask(link, CALL_MS) do |reply| Msg.Ack(lease, reply) end },
    nack: ->(lease, how) { ask(link, CALL_MS) do |reply| Msg.Nack(lease, how, reply) end },
    extend: ->(lease, ms) { ask(link, CALL_MS) do |reply| Msg.Extend(lease, ms, reply) end },
    counts: ->(queue) { ask(link, CALL_MS) do |reply| Msg.Counts(queue, reply) end },
    close: ->(drain_ms) { close(link, drain_ms) },
  )
end

def closed_error[T]() -> Result[T] = error("jobs error: the backend is closed", kind: "jobs.closed")

# A call that gives the actor's answer, or says why there is none: the backend was closed (the actor is gone), or the
# actor did not answer in time.
def ask[R](link: Link, wait_ms: Int, make: Fn[Channel[Result[R]], Msg]) -> Result[R]
  return closed_error() if link.closed.has_key?(CLOSED)

  case Actor.call(link.address, wait_ms, make)
    ok(answer) -> answer
    error(_) if link.closed.has_key?(CLOSED) -> closed_error()
    error(e) if e.message.start_with?("address: gone") -> closed_error()
    error(e) -> error("jobs error: the memory backend did not answer in time (#{e.message})", kind: "jobs.timeout")
  end
end

# A fetch that waits also ends, with no jobs, when the actor has not answered by then: the actor puts the jobs it has
# taken back.
def fetch_jobs(link: Link, fetch: Types.Fetch) -> Result[List[Types.Lease]]
  wait_ms = fetch.wait_ms.clamp(0, MAX_WAIT_MS)
  answer: Result[List[Types.Lease]] = ask(link, wait_ms + CALL_MS) do |reply| Msg.Fetch(fetch, reply) end
  case answer
    error(e) if e.is_a?("jobs.timeout") and wait_ms > 0 -> ok([])
    _ -> answer
  end
end

def close(link: Link, drain_ms: Int) -> Void
  return if not link.closed.put_new(CLOSED, 1)

  _ = Actor.stop(link.ref, drain_ms.clamp(1, MAX_WAIT_MS))
end

def handle(state: State, msg: Msg) -> Actor.Step[State]
  now = state.clock.call()
  ticked = state.with(store: Store.tick(state.store, now))
  Actor.continue(wake_parked(serve(ticked, now, msg), now))
end

def serve(state: State, now: Int, msg: Msg) -> State
  case msg
    Msg.Enqueue(jobs, reply) -> serve_enqueue(state, now, jobs, reply)
    Msg.Fetch(fetch, reply) -> serve_fetch(state, now, fetch, reply)
    Msg.Ack(lease, reply) -> serve_ack(state, lease, reply)
    Msg.Nack(lease, how, reply) -> serve_nack(state, lease, how, reply)
    Msg.Extend(lease, ms, reply) -> serve_extend(state, now, lease, ms, reply)
    Msg.Counts(queue, reply) -> reply_with(reply, ok(Store.counts(state.store, now, queue)), state)
  end
end

def serve_enqueue(
  state: State,
  now: Int,
  jobs: List[Types.NewJob],
  reply: Channel[Result[List[Types.Enqueued]]],
) -> State
  case Store.enqueue(state.store, now, jobs)
    ok(added) -> reply_with(reply, ok(added.enqueued), state.with(store: added.store))
    error(e) -> reply_with(reply, error(e), state)
  end
end

def serve_fetch(state: State, now: Int, fetch: Types.Fetch, reply: Channel[Result[List[Types.Lease]]]) -> State
  case Store.take(state.store, now, fetch)
    error(e) -> reply_with(reply, error(e), state)
    ok(taken) if taken.leases.empty? and fetch.wait_ms > 0 ->
      state.with(parked: state.parked.push(Waiter(fetch: fetch, until_ms: now + fetch.wait_ms, reply: reply)))
    ok(taken) -> deliver(state, taken, reply)
  end
end

def serve_ack(state: State, lease: Types.Lease, reply: Channel[Result[Void]]) -> State
  case Store.ack(state.store, lease)
    ok(store) -> reply_with(reply, ok(), state.with(store: store))
    error(e) -> reply_with(reply, error(e), state)
  end
end

def serve_nack(state: State, lease: Types.Lease, how: Types.Nack, reply: Channel[Result[Void]]) -> State
  case Store.nack(state.store, lease, how)
    ok(store) -> reply_with(reply, ok(), state.with(store: store))
    error(e) -> reply_with(reply, error(e), state)
  end
end

def serve_extend(state: State, now: Int, lease: Types.Lease, ms: Int, reply: Channel[Result[Types.Lease]]) -> State
  case Store.extend(state.store, now, lease, ms)
    ok(extended) -> reply_with(reply, ok(extended.lease), state.with(store: extended.store))
    error(e) -> reply_with(reply, error(e), state)
  end
end

# The answer is not lost when the caller gave up: the operation already happened, and a caller that retries gets the
# error of the new state.
def reply_with[R](reply: Channel[Result[R]], answer: Result[R], state: State) -> State
  _ = Actor.reply(reply, answer)
  state
end

# Jobs that nobody receives (the caller gave up) go back to their queue, and do not count as an attempt.
def deliver(state: State, taken: Store.Taken, reply: Channel[Result[List[Types.Lease]]]) -> State
  if Actor.reply(reply, ok(taken.leases))
    state.with(store: taken.store)
  else
    state.with(store: Store.untake(taken.store, taken.leases))
  end
end

# Serves the parked fetches in the order they came: the ones that get jobs, and the ones whose time is up, leave.
def wake_parked(state: State, now: Int) -> State
  current = state
  still: List[Waiter] = []
  for waiter in state.parked
    case Store.take(current.store, now, waiter.fetch)
      error(e) -> current = reply_with(waiter.reply, error(e), current)
      ok(taken) if taken.leases.empty? and waiter.until_ms > now -> still = still.push(waiter)
      ok(taken) -> current = deliver(current, taken, waiter.reply)
    end
  end

  current.with(parked: still)
end

def wake(state: State) -> Actor.Step[State]
  now = state.clock.call()
  ticked = state.with(store: Store.tick(state.store, now))
  Actor.continue(wake_parked(ticked, now))
end

# How long until something may change for a parked fetch: a job due, a lease to expire, or a deadline.
def wake_in(state: State) -> Optional[Int]
  return none if state.parked.empty?

  now = state.clock.call()
  times: List[Int] = []
  for waiter in state.parked
    times = times.push(waiter.until_ms)
    case Store.next_due(state.store, waiter.fetch.queue)
      some(at) -> times = times.push(at)
      none -> nil
    end
  end

  case times.min
    some(at) -> some((at - now).clamp(1, WAKE_CAP_MS))
    none -> none
  end
end

# The actor ends with `close`: the fetches that wait are told.
def shutdown(state: State) -> Void
  for waiter in state.parked
    _ = Actor.reply(waiter.reply, closed_error())
  end
end

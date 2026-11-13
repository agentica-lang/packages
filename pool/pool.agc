## A generic pool of resources (the idea of Elixir's NimblePool): a fixed number of long-lived resources of any type
## `W`, made and ended by the functions of a `Spec`, lent to the body of `Pool.with` one caller at a time.
##
## One owner task holds the state of the resources and the line of callers (first come, first served), and runs none of
## the functions of the `Spec`. Each resource has a keeper task that makes it (so it owns the resource's handles),
## pings it, runs `checkin` when `lease_ms` is above 0, and ends it. The caller uses the resource directly and gives it
## back when its body ends: the body runs in a task of its own when `lease_ms` is above 0, or in the caller when it is
## 0. A caller that crashes or is cancelled while it holds a resource does not keep it: the owner sees its task end,
## and the resource is checked in by its keeper or ended and replaced, never lost. Cancelling a caller cancels its body.
##
## Start the pool in a task that lives as long as the pool (`main`): the owner task ends with the task that started it.

import Keeper from "src/keeper"
import Owner from "src/owner"
import Types from "src/types"

export Types.Outcome
export Types.Spec

## A running pool. Share it with every task that needs a resource. `owner` is the owner task. `counts` is kept by the
## pool, to read: `waiting` (the callers in line), `live` (the resources made, being made or being ended), and
## `closed` once `close` has run; `waiting` and `live` are 0 once the close is over.
struct Pool[A, W]
  spec: Types.Spec[A, W]
  owner: Task[Void]
  counts: ATS[String, Int]

  private

  inbox: Channel[Types.Msg[W]]
end

## Starts a pool and waits for it to make its resources (none when `lazy`). An `init` that fails stops the start
## with its error, after ending the resources already made.
def start[A, W](spec: Types.Spec[A, W]) -> Result[Pool[A, W]]
  try check_spec(spec)
  chans: Owner.Chans[W] = Owner.chans()
  counts: ATS[String, Int] = ATS.new()
  owner = spawn_owner(chans) do |owned| Owner.own(spec, counts, owned) end
  case chans.ready.recv(START_MS)
    ok(started) -> started_pool(chans, Pool(spec: spec, owner: owner, counts: counts, inbox: chans.inbox), started)
    error(_) if chans.ready.closed? -> error("pool error: owner task ended during the start", kind: "pool.closed")
    error(_) ->
      Task.cancel(owner)
      error("pool error: start timed out after #{START_MS} ms", kind: "pool.timeout")
  end
end

## Runs the body with a resource of the pool and gives its result. With `lease_ms` above 0 the body runs in a task of
## the pool, so a crash in it is an `error` here, and one that runs past `lease_ms` is cancelled; `checkout` runs in
## that task, before the body, and the caller waits for it for at most HOOK_MS, and `checkin` runs in a task of its own,
## bounded. With 0 the body, `checkout` and `checkin` run in the caller, and a crash in them is the caller's own. Errors, each with a kind: `pool error: checkout timed out after N ms` (`pool.timeout.checkout`;
## the caller waited that long for a resource, with the last error of `init` as its cause if the pool could not make
## one), `pool error: lease timed out after N ms` (`pool.timeout.lease`), `pool error: queue full (max_waiting N)`
## (`pool.full`), `pool error: closed` and `pool error: owner task ended` (`pool.closed`). A caller that got one of
## these errors never has its body run later.
def with[A, W, R](pool: Pool[A, W], body: Fn[W, Result[R]]) -> Result[R]
  return closed(pool) if pool.counts.has_key?(CLOSED)

  deadline = Time.monotonic_ms() + pool.spec.checkout_ms
  lease = try take(pool, deadline)
  return in_caller(pool, lease, body) if pool.spec.lease_ms == 0

  in_leased(pool, lease, body, deadline)
end

## Refuses new callers, lets the running bodies and the callers in line finish for up to `drain_ms`, fails the rest
## with `pool error: closed` (a body that runs in a task of the pool is cancelled; one that runs in its caller finds
## its resource ended), ends every resource and stops the pool. Closing twice does nothing.
def close[A, W](pool: Pool[A, W], drain_ms: Int) -> Void
  return if not pool.counts.put_new(CLOSED, 1)

  done: Channel[Bool] = Channel.new(1)
  drain = [drain_ms, 0].max.unwrap!
  if pool.inbox.send(Types.Msg.Close(Types.Closing(drain_ms: drain, done: done)), SEND_MS).ok?
    _ = done.recv(drain + CLOSE_WAIT_MS)
  end

  Task.cancel(pool.owner)
end

## True for the error of a checkout or a lease that ran out of time. An `Error` tells the same with
## `e.is_a?("pool.timeout")`.
def timeout?(message: String) -> Bool = message.start_with?(CHECKOUT_TIMEOUT) or message.start_with?(LEASE_TIMEOUT)

private

START_MS = 60_000
SEND_MS = 5_000
# How long `close` waits after the drain: the owner gives the keepers 6 seconds to end their resources.
CLOSE_WAIT_MS = 8_000
# A body that ran past `lease_ms` is cancelled and given a moment to stop before `checkin` sees it.
CANCEL_GRACE_MS = 20
OWNER_CHECK_MS = 200
# How often the caller looks at the task of its body while `checkout` runs in it.
VET_SLICE_MS = 20
MAX_RESOURCES = 1_048_576
CLOSED = "closed"
CHECKOUT_TIMEOUT = "pool error: checkout timed out"
LEASE_TIMEOUT = "pool error: lease timed out"

def spawn_owner[W](chans: Owner.Chans[W], body: Fn[Owner.Chans[W], Void]) -> Task[Void]
  Task.spawn_owning(body, chans)
end

def started_pool[A, W](chans: Owner.Chans[W], pool: Pool[A, W], started: Result[Void]) -> Result[Pool[A, W]]
  case started
    ok(_) -> ok(pool)
    error(e) ->
      # The owner ends the resources already made, then ends, which closes `ready`.
      _ = chans.ready.recv(START_MS)
      error(e)
  end
end

def check_spec[A, W](spec: Types.Spec[A, W]) -> Result[Void]
  return argument("size must be at least 1, got #{spec.size}") if spec.size < 1

  if spec.size + spec.max_overflow > MAX_RESOURCES
    return argument("size + max_overflow cannot be more than #{MAX_RESOURCES}")
  end

  if spec.checkout_ms < 1 or spec.lease_ms < 0
    return argument("checkout_ms must be at least 1, and lease_ms 0 or more")
  end

  if (
    spec.max_overflow < 0 or
    spec.overflow_idle_ms < 0 or
    spec.max_age_ms < 0 or
    spec.idle_ms < 0 or
    spec.max_waiting < 0 or
    spec.health_ms < 0
  )
    return argument(
      "max_overflow, overflow_idle_ms, max_age_ms, idle_ms, max_waiting and health_ms cannot be negative",
    )
  end

  if (spec.max_age_ms > 0 or spec.idle_ms > 0) and spec.health_ms == 0
    return argument("max_age_ms and idle_ms need health_ms, which applies them")
  end

  if spec.idle_ms > 0 and not spec.lazy
    return argument("idle_ms needs a lazy pool, which does not make a new resource at once")
  end

  ok()
end

def argument(text: String) -> Result[Void] = error("pool error: #{text}", kind: "argument")

# The pool was closed, or its owner task ended with the task that started it.
def closed[A, W, T](pool: Pool[A, W]) -> Result[T]
  return error("pool error: closed", kind: "pool.closed") if pool.counts.has_key?(CLOSED)

  error("pool error: owner task ended", kind: "pool.closed")
end

# Asks the owner for a resource and waits for it until `deadline`. The ticket is the channel of the answer: a caller
# that gives up closes it, so the owner's send fails and the resource goes to the next caller; a resource sent just
# before the close is read and given back.
def take[A, W](pool: Pool[A, W], deadline: Int) -> Result[Types.Lease[W]]
  left = deadline - Time.monotonic_ms()
  return timed_out(pool) if left < 1

  reply: Channel[Types.Grant[W]] = Channel.new(1)
  sent = pool.inbox.send(Types.Msg.Checkout(Types.Ticket(reply: reply, client: Task.current())), left)
  return closed(pool) if pool.inbox.closed?

  return timed_out(pool) if not sent.ok?

  wait_grant(pool, reply, deadline)
end

# Waits in slices of OWNER_CHECK_MS, so that a caller hears soon that the owner task has ended (its inbox closes).
def wait_grant[A, W](pool: Pool[A, W], reply: Channel[Types.Grant[W]], deadline: Int) -> Result[Types.Lease[W]]
  left = deadline - Time.monotonic_ms()
  while left > 0 and not pool.inbox.closed?
    case reply.recv(left.clamp(1, OWNER_CHECK_MS))
      ok(grant) -> return granted(pool, grant, deadline)
      error(_) -> left = deadline - Time.monotonic_ms()
    end
  end

  give_up(pool, reply)
end

def granted[A, W](pool: Pool[A, W], grant: Types.Grant[W], deadline: Int) -> Result[Types.Lease[W]]
  case grant
    Types.Grant.Lent(lease) -> lendable(pool, lease, deadline)
    Types.Grant.Refused(Types.Refusal.Full) ->
      error("pool error: queue full (max_waiting #{pool.spec.max_waiting})", kind: "pool.full")
    Types.Grant.Refused(_) -> closed(pool)
  end
end

# `checkout` of the Spec for a body that runs in its caller (`lease_ms` 0): it runs here, unbounded. With `lease_ms`
# above 0 it runs in the task of the body (`vetted?`). A resource it refuses is ended, and the caller waits again
# at the
# front of the line, in the same message, so that it keeps its place even when the line is full.
def lendable[A, W](pool: Pool[A, W], lease: Types.Lease[W], deadline: Int) -> Result[Types.Lease[W]]
  case pool.spec.checkout
    some(check) if pool.spec.lease_ms == 0 and not check.call(lease.worker).ok? -> again(pool, lease, deadline)
    _ -> ok(lease)
  end
end

def again[A, W](pool: Pool[A, W], lease: Types.Lease[W], deadline: Int) -> Result[Types.Lease[W]]
  reply: Channel[Types.Grant[W]] = Channel.new(1)
  give_back(pool, lease, Types.Return.Again(Types.Ticket(reply: reply, client: Task.current())))
  return closed(pool) if pool.inbox.closed?

  wait_grant(pool, reply, deadline)
end

def give_up[A, W](pool: Pool[A, W], reply: Channel[Types.Grant[W]]) -> Result[Types.Lease[W]]
  reply.close
  case reply.recv(0)
    ok(Types.Grant.Lent(lease)) -> give_back(pool, lease, Types.Return.Keep)
    _ -> nil
  end

  return closed(pool) if pool.inbox.closed?

  timed_out(pool)
end

def timed_out[A, W, T](pool: Pool[A, W]) -> Result[T]
  text = "#{CHECKOUT_TIMEOUT} after #{pool.spec.checkout_ms} ms"
  case last_failure(pool)
    error(e) -> error("#{text} (the last init failed: #{e.message})", kind: "pool.timeout.checkout", cause: e)
    ok(_) -> error(text, kind: "pool.timeout.checkout")
  end
end

# The last error of `init`, while no resource could be made since; `ok` when there is none or the owner is gone.
def last_failure[A, W](pool: Pool[A, W]) -> Result[Void]
  answer: Channel[Result[Void]] = Channel.new(1)
  return ok() if not pool.inbox.send(Types.Msg.Failure(answer), SEND_MS).ok?

  case answer.recv(SEND_MS)
    ok(failure) -> failure
    error(_) -> ok()
  end
end

# `lease_ms` 0: the body and `checkin` run here. A crash ends the caller's task, and the owner, which watches it, has
# the keeper check the resource in.
def in_caller[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], body: Fn[W, Result[R]]) -> Result[R]
  result = body.call(lease.worker)
  # The owner learns first that `checkin` runs, so that if the caller ends during it the keeper does not run it again:
  # the resource is ended instead.
  _ = pool.inbox.send(Types.Msg.Returning(Types.Held(id: lease.id, seq: lease.seq)), SEND_MS)
  if pool.spec.checkin.call(lease.worker, Types.Outcome.Done).ok?
    give_back(pool, lease, Types.Return.Keep)
  else
    give_back(pool, lease, Types.Return.Drop)
  end

  result
end

# A body that runs in a task of its own (`lease_ms` above 0): the resource is refused by `checkout` or the body runs. A
# refused resource is ended, and the caller waits again at the front of the line for the next one.
def in_leased[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], body: Fn[W, Result[R]], deadline: Int) -> Result[R]
  case in_runner(pool, lease, body)
    some(result) -> result
    none ->
      next = try again(pool, lease, deadline)
      in_leased(pool, next, body, deadline)
  end
end

# The body runs in a task of its own: first `checkout` when the Spec has one (the caller waits for that for at most
# HOOK_MS), then it tells the owner who it is, so that a close can cancel it, then the body. Its own Result goes
# inside another, so that a crash or a cancel (the outer error) is told apart from an error the body gave. The keeper
# runs `checkin`, in a task of its own for HOOK_MS, after the caller has its result: one that crashes or hangs ends the
# resource, never the caller. `none` is a resource that `checkout` refused, crashed on or hung on, and the caller never
# saw it.
def in_runner[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], body: Fn[W, Result[R]]) -> Optional[Result[R]]
  verdict: Channel[Bool] = Channel.new(1)
  runner = Task.spawn do
    case pool.spec.checkout
      some(check) ->
        passed = check.call(lease.worker).ok?
        _ = verdict.send(passed, 0)
        return error("checkout refused") if not passed
      none -> nil
    end

    # The owner learns who runs the body only now, so that a caller that ends during `checkout` has no `checkin` (its
    # body never started); a lease that is over by now (the end of a drain) has the owner cancel this task, and a pool
    # that is gone (its inbox is closed) runs no body.
    told = pool.inbox.send(Types.Msg.Run(Types.Running(id: lease.id, seq: lease.seq, runner: Task.current())), SEND_MS)
    return error("pool error: closed", kind: "pool.closed") if not told.ok?

    ok(body.call(lease.worker))
  end

  return none if pool.spec.checkout.some? and not vetted?(verdict, runner)

  case Task.await(runner, pool.spec.lease_ms)
    Await.Done(ran) -> some(ran_out(pool, lease, ran))
    Await.TimedOut ->
      Task.cancel(runner)
      Task.sleep(CANCEL_GRACE_MS)
      hand_in(lease, Types.Outcome.TimedOut)
      some(error("#{LEASE_TIMEOUT} after #{pool.spec.lease_ms} ms", kind: "pool.timeout.lease"))
  end
end

# Whether `checkout` passed, as the runner says on `verdict`. A runner that ended without saying (a crash
# in `checkout`)
# or has not said within HOOK_MS (a hang, which is cancelled) did not pass. The caller looks at the runner every
# VET_SLICE_MS, so a crash is heard at once and not at the end of HOOK_MS.
def vetted?[R](verdict: Channel[Bool], runner: Task[Result[Result[R]]]) -> Bool
  until = Time.monotonic_ms() + Keeper.HOOK_MS
  while Time.monotonic_ms() < until
    case verdict.recv((until - Time.monotonic_ms()).clamp(1, VET_SLICE_MS))
      ok(passed) -> return passed
      error(_) -> nil
    end

    case Task.await(runner, 1)
      Await.Done(_) -> return verdict.recv(0).unwrap_or(false)
      Await.TimedOut -> nil
    end
  end

  Task.cancel(runner)
  false
end

def ran_out[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], ran: Result[Result[R]]) -> Result[R]
  case ran
    ok(result) ->
      hand_in(lease, Types.Outcome.Done)
      result
    error(e) if e.is_a?("task.cancelled") and pool.counts.has_key?(CLOSED) -> closed(pool)
    error(e) if e.is_a?("pool.closed") -> closed(pool)
    error(e) ->
      hand_in(lease, Types.Outcome.Crashed)
      error(e)
  end
end

# Asks the keeper of the resource to run `checkin` and give it back. A send that fails means that the resource was
# ended meanwhile.
def hand_in[W](lease: Types.Lease[W], outcome: Types.Outcome) -> Void
  _ = lease.orders.send(Types.Order.Checkin(Types.Turn(seq: lease.seq, outcome: outcome)), SEND_MS)
end

# A send that fails means the pool is closed, and the close ends the resource.
def give_back[A, W](pool: Pool[A, W], lease: Types.Lease[W], how: Types.Return[W]) -> Void
  _ = pool.inbox.send(Types.Msg.Checkin(Types.Back(id: lease.id, seq: lease.seq, how: how)), SEND_MS)
end

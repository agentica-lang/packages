## A generic pool of resources (the idea of Elixir's NimblePool): a fixed number of long-lived resources of any type
## `W`, made and ended by the functions of a `Spec`, lent to the body of `Pool.with` one caller at a time.
##
## One owner task holds the state of the resources and the line of callers (first come, first served), and runs none of
## the functions of the `Spec`. Each resource has a keeper task that makes it (so it owns the resource's handles),
## pings it and ends it. The caller uses the resource directly and gives it back when its body ends: the body runs in a
## task of its own when `lease_ms` is above 0, or in the caller when it is 0. A caller that crashes or is cancelled
## while it holds a resource does not keep it: the owner sees its task end, and the resource is checked in by its
## keeper or ended and replaced, never lost. Cancelling a caller cancels its body.
##
## Start the pool in a task that lives as long as the pool (`main`): the owner task ends with the task that started it.

import Keeper from "src/keeper"
import Owner from "src/owner"
import Types from "src/types"

export Types.Outcome
export Types.Spec

## A running pool. Share it with every task that needs a resource.
struct Pool[A, W]
  spec: Types.Spec[A, W]

  private

  inbox: Channel[Types.Msg[W]]
  owner: Task[Void]
  flags: ATS[String, Int]
end

## Starts a pool and waits for it to make its resources (none when `lazy`). An `init` that fails stops the start
## with its error, after ending the resources already made.
def start[A, W](spec: Types.Spec[A, W]) -> Result[Pool[A, W]]
  try check_spec(spec)
  chans: Owner.Chans[W] = Owner.chans()
  owner = spawn_owner(chans) do |owned| Owner.own(spec, owned) end
  case chans.ready.recv(START_MS)
    ok(started) -> started_pool(spec, chans, owner, started)
    error(_) if chans.ready.closed? -> error("pool error: owner task ended during the start", kind: "pool.closed")
    error(_) ->
      Task.cancel(owner)
      error("pool error: start timed out after #{START_MS} ms", kind: "pool.timeout")
  end
end

## Runs the body with a resource of the pool and gives its result. `checkout` and `checkin` of the `Spec` run in the
## caller, before and after the body. With `lease_ms` above 0 the body runs in a task of the pool, so a crash in it is
## an `error` here, and one that runs past `lease_ms` is cancelled; with 0 it runs in the caller, and a crash in it is
## the caller's own. Errors, each with a kind: `pool error: checkout timed out after N ms` (`pool.timeout.checkout`;
## the caller waited that long for a resource, with the last error of `init` as its cause if the pool could not make
## one), `pool error: lease timed out after N ms` (`pool.timeout.lease`), `pool error: queue full (max_waiting N)`
## (`pool.full`), `pool error: closed` and `pool error: owner task ended` (`pool.closed`). A caller that got one of
## these errors never has its body run later.
def with[A, W, R](pool: Pool[A, W], body: Fn[W, Result[R]]) -> Result[R]
  return closed(pool) if pool.flags.has_key?(CLOSED)

  checkout_ms = pool.spec.checkout_ms
  lease = try take(pool, Time.monotonic_ms() + checkout_ms)
  return in_caller(pool, lease, body) if pool.spec.lease_ms == 0

  in_runner(pool, lease, body)
end

## Refuses new callers, lets the running bodies and the callers in line finish for up to `drain_ms`, fails the rest
## with `pool error: closed` (a body that runs in a task of the pool is cancelled; one that runs in its caller finds
## its resource ended), ends every resource and stops the pool. Closing twice does nothing.
def close[A, W](pool: Pool[A, W], drain_ms: Int) -> Void
  return if not pool.flags.put_new(CLOSED, 1)

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
# How long `close` waits after the drain: the owner gives the keepers 2 seconds to end their resources.
CLOSE_WAIT_MS = 5_000
# A body that ran past `lease_ms` is cancelled and given a moment to stop before `checkin` sees it.
CANCEL_GRACE_MS = 20
MAX_RESOURCES = 1_048_576
CLOSED = "closed"
CHECKOUT_TIMEOUT = "pool error: checkout timed out"
LEASE_TIMEOUT = "pool error: lease timed out"

def spawn_owner[W](chans: Owner.Chans[W], body: Fn[Owner.Chans[W], Void]) -> Task[Void]
  Task.spawn_owning(body, chans)
end

def started_pool[A, W](
  spec: Types.Spec[A, W],
  chans: Owner.Chans[W],
  owner: Task[Void],
  started: Result[Void],
) -> Result[Pool[A, W]]
  flags: ATS[String, Int] = ATS.new()
  case started
    ok(_) -> ok(Pool(spec: spec, inbox: chans.inbox, owner: owner, flags: flags))
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
  return error("pool error: closed", kind: "pool.closed") if pool.flags.has_key?(CLOSED)

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

def wait_grant[A, W](pool: Pool[A, W], reply: Channel[Types.Grant[W]], deadline: Int) -> Result[Types.Lease[W]]
  case reply.recv([deadline - Time.monotonic_ms(), 0].max.unwrap!)
    ok(grant) -> granted(pool, grant, deadline)
    error(_) -> give_up(pool, reply)
  end
end

def granted[A, W](pool: Pool[A, W], grant: Types.Grant[W], deadline: Int) -> Result[Types.Lease[W]]
  case grant
    Types.Grant.Lent(lease) -> lendable(pool, lease, deadline)
    Types.Grant.Refused(Types.Refusal.Full) ->
      error("pool error: queue full (max_waiting #{pool.spec.max_waiting})", kind: "pool.full")
    Types.Grant.Refused(_) -> closed(pool)
  end
end

# `checkout` of the Spec, in the caller (`lease_ms` 0) or in a task of its own for HOOK_MS. A resource it refuses is
# ended, and the caller waits again at the front of the line, in the same message, so that it keeps its place even
# when the line is full.
def lendable[A, W](pool: Pool[A, W], lease: Types.Lease[W], deadline: Int) -> Result[Types.Lease[W]]
  case pool.spec.checkout
    some(check) if not checked_out?(pool, check, lease.worker) ->
      reply: Channel[Types.Grant[W]] = Channel.new(1)
      give_back(pool, lease, Types.Return.Again(Types.Ticket(reply: reply, client: Task.current())))
      return closed(pool) if pool.inbox.closed?

      wait_grant(pool, reply, deadline)
    _ -> ok(lease)
  end
end

def checked_out?[A, W](pool: Pool[A, W], check: Fn[W, Result[Void]], worker: W) -> Bool
  return check.call(worker).ok? if pool.spec.lease_ms == 0

  Keeper.settled?(Task.spawn do check.call(worker) end)
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

# `lease_ms` 0: the body and `checkin` run here. The owner learns first that `checkin` runs, so that if the caller
# ends during it the keeper does not run it again: the resource is ended instead. A crash ends the caller's task, and
# the owner, which watches it, has the keeper check the resource in.
def in_caller[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], body: Fn[W, Result[R]]) -> Result[R]
  result = body.call(lease.worker)
  _ = pool.inbox.send(Types.Msg.Returning(Types.Held(id: lease.id, seq: lease.seq)), SEND_MS)
  if pool.spec.checkin.call(lease.worker, Types.Outcome.Done).ok?
    give_back(pool, lease, Types.Return.Keep)
  else
    give_back(pool, lease, Types.Return.Drop)
  end

  result
end

# The body runs in a task of its own, which tells the owner who it is, so that a close can cancel it. Its own Result
# goes inside another, so that a crash or a cancel (the outer error) is told apart from an error the body gave. The
# keeper runs `checkin`, in a task of its own for HOOK_MS, after the caller has its result.
def in_runner[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], body: Fn[W, Result[R]]) -> Result[R]
  runner = Task.spawn do
    _ = pool.inbox.send(Types.Msg.Run(Types.Running(id: lease.id, seq: lease.seq, runner: Task.current())), SEND_MS)
    ok(body.call(lease.worker))
  end

  case Task.await(runner, pool.spec.lease_ms)
    Await.Done(ran) -> ran_out(pool, lease, ran)
    Await.TimedOut ->
      Task.cancel(runner)
      Task.sleep(CANCEL_GRACE_MS)
      give_back(pool, lease, Types.Return.Check(Types.Outcome.TimedOut))
      error("#{LEASE_TIMEOUT} after #{pool.spec.lease_ms} ms", kind: "pool.timeout.lease")
  end
end

def ran_out[A, W, R](pool: Pool[A, W], lease: Types.Lease[W], ran: Result[Result[R]]) -> Result[R]
  case ran
    ok(result) ->
      give_back(pool, lease, Types.Return.Check(Types.Outcome.Done))
      result
    error(e) if e.is_a?("task.cancelled") and pool.flags.has_key?(CLOSED) -> closed(pool)
    error(e) ->
      give_back(pool, lease, Types.Return.Check(Types.Outcome.Crashed))
      error(e)
  end
end

# A send that fails means the pool is closed, and the close ends the resource.
def give_back[A, W](pool: Pool[A, W], lease: Types.Lease[W], how: Types.Return[W]) -> Void
  _ = pool.inbox.send(Types.Msg.Checkin(Types.Back(id: lease.id, seq: lease.seq, how: how)), SEND_MS)
end

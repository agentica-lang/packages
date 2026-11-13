## The records that the files of the pool share. `pool.agc` re-exports the public ones (`Outcome`, `Spec`); the
## others are the messages between the callers, the owner task and the keeper tasks.

## How a body ended, as `checkin` sees it. `TimedOut` is a body that was cut off: it ran past `lease_ms`, or its
## caller was cancelled, so it may still run for a moment.
enum Outcome
  Done
  Crashed
  TimedOut
end

## What a pool is made of. `init` makes a worker from `config` in a task of its own for each worker (its keeper), which
## owns the handles it opens; `terminate` ends it there. An `init` that never returns holds its place: the pool counts
## that worker as being made, and so does a `terminate` that never returns (it runs in the keeper, which owns the
## handles, so it has no limit). `checkout` (when given) runs before the body: in the caller when `lease_ms` is 0, else
## in the task of the body, which the caller waits for at most 5 seconds. Its `error` (or a crash, or a hang) ends that
## worker, and the caller gets the next one at the front of the line. `checkin` gets the worker back after each body
## that ran, at most once (`error` ends it: it is terminated and replaced): in the caller when `lease_ms` is 0, with no
## limit; else in the keeper, in a task of its own for at most 5 seconds, after the caller has its result, so one that
## crashes or hangs ends the worker and never reaches the caller. `ping` checks an idle worker at the health tick, in
## its keeper (`error` ends it). No function of the spec runs in the owner task of the pool, so none can stall or end
## it.
##
## After a `TimedOut` body the worker is always terminated and replaced, whatever `checkin` returns: the cancelled body
## may still run for a moment, so nobody else may get the worker. After `Crashed` the body is dead, and `checkin`
## decides.
##
## `size` workers are kept. In a spike the pool makes up to `max_overflow` more (so `size + max_overflow` is the most
## that exist, also while one is being ended). When a spike is over, an overflow worker that nobody needs stays for
## `overflow_idle_ms` and is ended if it is still idle then (0 ends it as soon as it is given back), so the pool shrinks
## back to `size` and a steady load a little over `size` does not make and end a worker for every request. A `lazy`
## pool makes its workers when callers need them. `checkout_ms` is how long a caller waits for a worker. `lease_ms` is
## how long a body may run: the body runs in a task of its own, cancelled after that long; 0 runs the body in the
## caller, with no limit. `max_age_ms` and `idle_ms` need `health_ms` (the health tick is what applies them) and 0
## turns each off; `idle_ms` needs a lazy pool, since an eager pool would make a new worker at once. The health tick
## pings the workers idle for `health_ms` or more. `max_waiting` is how many callers may wait in line for a busy
## worker at once (0 or more); the callers that a worker being made, pinged or checked in will serve, or one that the
## pool can still make, do not count. One more is refused with `pool error: queue full (max_waiting N)`, and 0 lets
## nobody wait: a caller that finds every worker busy is refused, but a pool that can make a worker for it makes it.
struct Spec[A, W]
  config: A
  init: Fn[A, Result[W]]
  checkin: Fn[W, Outcome, Result[Void]]
  terminate: Fn[W, Void]
  ping: Fn[W, Result[Void]]
  checkout: Optional[Fn[W, Result[Void]]] = none
  size: Int = 10
  max_overflow: Int = 0
  overflow_idle_ms: Int = 1_000
  checkout_ms: Int = 5_000
  lease_ms: Int = 30_000
  max_age_ms: Int = 0
  idle_ms: Int = 0
  max_waiting: Int = 1_000
  lazy: Bool = false
  health_ms: Int = 5_000
end

## A caller in line: the channel of its answer (room for one), and its task, which the owner watches.
struct Ticket[W]
  reply: Channel[Grant[W]]
  client: TaskRef
end

## A worker lent to a caller, with the number of this lease, which every message about it carries: a message of an
## earlier lease of the same worker changes nothing. `orders` is the channel of the worker's keeper, where a caller
## whose body ran in a task of the pool (`lease_ms` above 0) asks for `checkin`.
struct Lease[W]
  id: Int
  seq: Int
  worker: W
  orders: Channel[Order]
end

## An order for the keeper of a worker: ping it while it is idle, or run `checkin` after the lease `seq`. Its caller
## and the owner (for a caller that is gone, or at the end of a close) may both ask for the same lease; the keeper runs
## the first and drops the other, so `checkin` runs at most once.
enum Order
  Ping(Int)
  Checkin(Turn)
end

## A `checkin` to run: the lease, and how its body ended.
struct Turn
  seq: Int
  outcome: Outcome
end

## The answer to a ticket.
enum Grant[W]
  Lent(Lease[W])
  Refused(Refusal)
end

enum Refusal
  Full
  Closed
end

## A lease that its caller ends: the caller runs `checkin` now (`lease_ms` 0), so its keeper must not run it again.
struct Held
  id: Int
  seq: Int
end

## A worker given back by its caller, and what becomes of it.
struct Back[W]
  id: Int
  seq: Int
  how: Return[W]
end

## `Keep` and `Drop`: the caller ran `checkin`, or never used the worker (`Keep`). `Again`: `checkout` refused the
## worker, which is ended, and the caller waits at the front of the line with a new ticket.
enum Return[W]
  Keep
  Drop
  Again(Ticket[W])
end

## The task that runs a body when `lease_ms` is above 0, which a close cancels at the end of its drain.
struct Running
  id: Int
  seq: Int
  runner: TaskRef
end

## What a keeper made.
struct Made[W]
  id: Int
  worker: Result[W]
end

## What a ping, or a `checkin` that a keeper ran, said, and for which lease (for a ping: the last one).
struct Checked
  id: Int
  seq: Int
  keep: Bool
end

## A close: how long the lent workers have to come back, and where to say that the pool has ended.
struct Closing
  drain_ms: Int
  done: Channel[Bool]
end

## The messages of the owner's inbox.
enum Msg[W]
  Checkout(Ticket[W])
  Returning(Held)
  Checkin(Back[W])
  Run(Running)
  Ready(Made[W])
  Check(Checked)
  Down(TaskDown)
  Failure(Channel[Result[Void]])
  Close(Closing)
end

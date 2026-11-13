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
## owns the handles it opens; `terminate` ends it there. `checkout` (when given) runs in the caller before its body:
## `error` ends that worker and the caller gets the next one. `checkin` gets the worker back after each body, in the
## caller (`error` ends it: it is terminated and replaced); `ping` checks an idle worker at each health tick, in its
## keeper (`error` ends it). No function of the spec runs in the owner task of the pool, so none can stall or end it.
##
## After a `TimedOut` body the worker is always terminated and replaced, whatever `checkin` returns: the cancelled body
## may still run for a moment, so nobody else may get the worker. After `Crashed` the body is dead, and `checkin`
## decides.
##
## `size` workers are kept. In a spike the pool makes up to `max_overflow` more (so `size + max_overflow` is the most
## that exist). When a spike is over, an overflow worker that nobody needs stays for `overflow_idle_ms` and is ended if
## it is still idle then (0 ends it as soon as it is given back), so the pool shrinks back to `size` and a steady load
## a little over `size` does not make and end a worker for every request. A `lazy` pool makes its workers when callers
## need them. `checkout_ms` is how long a caller waits for a worker. `lease_ms` is how long a body may run: the body
## runs in a task of its own, cancelled after that long; 0 runs the body in the caller, with no limit. `max_age_ms` and
## `idle_ms` need `health_ms` (the health tick is what applies them) and 0 turns each off; `idle_ms` needs a lazy pool,
## since an eager pool would make a new worker at once. `max_waiting` is how many callers may wait in line for a worker
## at once (0 or more); one more is refused with `pool error: queue full (max_waiting N)`, and 0 lets nobody wait: a
## caller that finds every worker busy is refused.
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
  place: Place
end

## Where a ticket goes in line: a caller whose worker `checkout` ended keeps its place at the front.
enum Place
  Back
  Front
end

## A worker lent to a caller.
struct Lease[W]
  id: Int
  worker: W
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

## A worker given back by its caller, kept or not.
struct Back
  id: Int
  keep: Bool
end

## The task that runs a body when `lease_ms` is above 0, which a close cancels at the end of its drain.
struct Running
  id: Int
  runner: TaskRef
end

## What a keeper made.
struct Made[W]
  id: Int
  worker: Result[W]
end

## What a ping, or a `checkin` that a keeper ran for a caller that is gone, said.
struct Checked
  id: Int
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
  Checkin(Back)
  Run(Running)
  Ready(Made[W])
  Check(Checked)
  Down(TaskDown)
  Failure(Channel[Result[Void]])
  Close(Closing)
end

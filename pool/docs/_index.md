---
title: pool
description: A generic pool of resources. A fixed number of long-lived resources, lent to one caller at a time, with a line, a lease, a health tick and a clean close.
---

`pool` is for any resource that is made once and lent to one caller at a time: a database connection, an HTTP connection, a worker. It has no native library. This is the generic pool that `agentica-db` uses for `DbPool`, with the same import path.

Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add pool https://github.com/agentica-lang/packages --tag pool-0.1.0 --subdir pool
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
pool = { git = "https://github.com/agentica-lang/packages", tag = "pool-0.1.0", subdir = "pool" }
```

A `Pool.Spec[A, W]` holds the config `A` and the functions that make, check and end the resources `W`. None of them runs in the owner task of the pool, so a slow or crashing one never stalls the pool or ends it:

- `init(config)` makes a resource. It runs in a task of its own for each resource (its keeper), which owns the handles it opens, so they stay open while the resource lives. An `init` that never returns holds its place: the pool counts that resource as being made.
- `checkout(resource)` (optional) runs before the body: in the caller with `lease_ms` 0, else in a task of its own for at most 5 seconds. An `error` (or a crash, or a hang) ends the resource, and the caller gets the next one without losing its place in line.
- `checkin(resource, outcome)` gets the resource back after each body that ran, once, with the outcome `Done`, `Crashed` or `TimedOut`. With `lease_ms` 0 it runs in the caller, with no limit. Above 0 it runs in the keeper, in a task of its own for at most 5 seconds, after the caller has its result: one that crashes or hangs ends the resource and never reaches the caller. An `error` ends the resource, and the pool makes another. After `TimedOut` the pool ends the resource whatever `checkin` returns, since the cancelled body may still run for a moment; after `Crashed` the body is dead and `checkin` decides.
- `ping(resource)` checks an idle resource at each health tick, in its keeper; an `error` ends it.
- `terminate(resource)` ends it, in its keeper.

`Pool.with(pool) do |resource| ... end` runs the body with a resource and gives its result. Callers wait in line, first come, first served. With `lease_ms` above 0 (the default) the body runs in a task of its own, so a crash in it is an `error` for the caller and the resource still comes back. With `lease_ms` 0 it runs in the caller, which is about three times faster: a crash in it is a crash of the caller.

```agentica
import Pool from "pkg/pool/pool"

struct Worker
  id: Int
end

def make(ids: ATS[String, Int]) -> Result[Worker]
  return ok(Worker(id: ids.add("next", 1)))
end

def check_in(worker: Worker, outcome: Pool.Outcome) -> Result[Void]
  case outcome
    Pool.Outcome.Done -> return ok()
    Pool.Outcome.Crashed -> return error("crashed")
    Pool.Outcome.TimedOut -> return error("timed out")
  end
end

def end_worker(worker: Worker) -> Void
  puts("ended worker #{worker.id}")
end

def ping(worker: Worker) -> Result[Void]
  return ok()
end

def main() -> Void
  ids: ATS[String, Int] = ATS.new()
  spec = Pool.Spec(config: ids, init: &make, checkin: &check_in, terminate: &end_worker, ping: &ping, size: 1)
  pool = Pool.start(spec).unwrap!
  puts(Pool.with(pool) do |worker| ok("worker #{worker.id}") end)
  Pool.close(pool, 1000)
end
```

```output
ok("worker 1")
ended worker 1
```

## API

```signature
Pool.start(spec: Spec[A, W]) -> Result[Pool[A, W]]
Pool.with(pool: Pool[A, W], body: Fn[W, Result[R]]) -> Result[R]
Pool.close(pool: Pool[A, W], drain_ms: Int) -> Void
Pool.timeout?(message: String) -> Bool
```

A `Pool` has the fields `spec`, `owner` (the owner task) and `counts`, which the pool keeps for reading: `waiting` (the callers in line, with those that gave up until the pool drops them), `live` (the resources made, being made or being ended) and `closed` once `close` has run. `waiting` and `live` are 0 once the close is over.

## The Spec

The other fields of the `Spec`, all in milliseconds unless noted, with their defaults:

- `checkout` (`none`): the check before each body, above.
- `size` (10): how many resources. With `lazy: true` (false) they are made when a caller needs one.
- `max_overflow` (0): in a spike the pool makes up to this many resources more, so `size + max_overflow` is the most that exist (at most 1048576 in all).
- `overflow_idle_ms` (1000): an overflow resource that no caller needs stays this long and is ended if it is still idle then, so the pool shrinks back to `size`, and a steady load a little over `size` does not make and end a resource for every request. 0 ends it as soon as it is given back.
- `checkout_ms` (5000): how long a caller waits for a resource.
- `lease_ms` (30000): how long a body may run. The body runs in a task of its own, and one past this time is cancelled and its caller gets an error. 0 runs the body in the caller, with no limit.
- `max_age_ms` (0) and `idle_ms` (0): a resource older than `max_age_ms` is ended and replaced; one unused for `idle_ms` is ended (`idle_ms` needs `lazy: true`, since an eager pool would make a new one at once). 0 turns the rule off. Both need `health_ms`, which applies them.
- `max_waiting` (1000): how many callers may wait for a busy resource at once, 0 or more. The callers that a resource being made, pinged or checked in will serve, or one the pool can still make, do not count. 0 lets nobody wait: a caller that finds every resource busy is refused, but a pool that can make a resource for it (lazy, or with overflow) makes it.
- `health_ms` (5000): the interval of the health tick, which pings the resources idle for `health_ms` or more and applies `max_age_ms` and `idle_ms`. A resource in use is never pinged. 0 turns the tick off.

## Errors

Each error of the pool has a kind, so a caller tests `e.is_a?("pool")` or a kind below, never the text:

| Kind | Message |
| --- | --- |
| `pool.timeout.checkout` | `pool error: checkout timed out after N ms`, with the last error of `init` (also as `cause`) when the pool could not make a resource |
| `pool.timeout.lease` | `pool error: lease timed out after N ms` |
| `pool.full` | `pool error: queue full (max_waiting N)` |
| `pool.closed` | `pool error: closed`, or `pool error: owner task ended` |
| `argument` | a field of the `Spec` out of range, at `Pool.start` |

`e.is_a?("pool.timeout")` is true for both timeouts, as `Pool.timeout?(message)` is for their text. An `init` that fails at the start of an eager pool stops the start with its own error. A body that crashes in its own task gives the crash (`task.crashed`). A caller that got a pool error never has its body run later, and a caller waits for a resource no longer than `checkout_ms`. A failed `init` is tried again after a second, not for every caller, and the callers that time out meanwhile see its error.

## Callers that end

The owner task watches the task of each caller. A caller that crashes or is cancelled while it holds a resource does not keep it: its keeper runs `checkin` with `Crashed` (a crash of a body that runs in the caller) or `TimedOut` (a cancel), and the resource comes back or is ended and replaced. `checkin` runs once for each body that ran: a caller that ends before its body started has its resource ended without it, and one that ends during its own `checkin` (`lease_ms` 0) too. Cancelling a caller cancels its body too, also when the body runs in a task of its own. A caller cancelled while it waits leaves the line.

A task that has used the pool counts its crash as observed, since the pool hears of it: a run whose only unobserved crash is in such a task does not exit 1 for it (the crash still prints). The fix belongs in the language ([agentica-lang/agentica#1522](https://github.com/agentica-lang/agentica/issues/1522)).

## Closing

`Pool.close(pool, drain_ms)` refuses new callers, lets the running bodies and the callers in line finish for up to `drain_ms`, fails the rest with `pool error: closed`, ends every resource and stops the pool.

- Start the pool in a task that lives as long as it does, such as `main`: the owner task ends with the task that started it.
- A body that runs in a task of its own and outlasts the drain is cancelled, its keeper runs `checkin` with `TimedOut`, and its caller gets `pool error: closed`. One that runs in its caller (`lease_ms` 0) is not cancelled: it finds its resource ended, and its result is its own.
- `ping`, `checkout` and `checkin` have 5 seconds each in a task of their own. The keepers have six seconds after the drain to end their resources, so one in such a call still runs `terminate`; a keeper that is still running then is cancelled, and the VM closes the handles it owns.
- A caller in line hears within a fifth of a second that the owner task has ended (`pool error: owner task ended`).

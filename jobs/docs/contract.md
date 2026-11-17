---
title: The contract
description: What every jobs backend guarantees, the records of the contract, and how to prove a backend with the conformance suite.
weight: 2
---

A backend is a `Jobs.Backend`: a record of functions, since Agentica has no traits. `Jobs.enqueue` and the others call its fields, as `Db.query` calls a connection, and a backend package fills them. A wrapper that replaces one field (`backend.with(fetch: ...)`) can log, count or inject faults.

```text
struct Backend
  name: String
  caps: Caps
  enqueue: Fn[List[NewJob], Result[List[Enqueued]]]
  fetch: Fn[Fetch, Result[List[Lease]]]
  ack: Fn[Lease, Result[Void]]
  nack: Fn[Lease, Nack, Result[Void]]
  extend: Fn[Lease, Int, Result[Lease]]
  counts: Fn[String, Result[Counts]]
  close: Fn[Int, Void]
end
```

## What every backend guarantees

1. **At least once.** After `enqueue` gives `ok`, the job is delivered until it is acked or dead. A consumer that crashes or hangs loses its lease when it runs out, and the job comes back.
2. **One live lease.** While a lease is live, no fetch gets that job. A new delivery has a new `token`, and ack, nack and extend with the old token fail with `jobs.lease_lost`.
3. **Not early.** No job is delivered before its `run_at_ms`.
4. **Attempts count at the fetch.** `attempt` is 1 on the first delivery and counts every delivery, also one whose lease ran out. A delivery past `max_attempts` does not happen: a lease that runs out on the last attempt makes the job dead, and so does a `Retry` on the last attempt. A job that crashes its consumer cannot loop forever. `Release` does not count.
5. **Unique keys.** While a job with the same queue and `unique_key` is ready, scheduled or leased, `enqueue` gives its id with `duplicate: true`. The key is free when the job is acked or dead.
6. **`enqueue_all` is all or nothing:** a job that is not valid, or that does not fit, fails the call and adds none.
7. **`close`** refuses new calls with `jobs.closed` and waits up to `drain_ms` for the backend to stop. Closing twice does nothing.

There is no order guarantee. Ready jobs come roughly by `run_at_ms`, then by insertion. Acked jobs are deleted, and dead jobs are kept (the memory backend keeps `max_dead` of them). The payload is bytes: every store holds bytes, and `Jobs.json` is the typed form on top.

Times are Unix milliseconds. A backend takes a clock option (`Fn[Int]`) and defaults to the wall clock, which a database also stores. The wall clock can jump: a jump forward ends leases early, and at-least-once still holds.

## The memory backend

`Jobs.memory(Jobs.MemoryOptions(...))` keeps the jobs in one actor. `max_jobs` (10 000) is how many live jobs it holds: past it `enqueue` fails with `jobs.full`, and a producer decides to log, drop or answer 503. `max_dead` (1 000) is how many dead jobs it keeps; the oldest is dropped. `clock` is the time source. Every call applies the clock first, so a lease that ran out is back before the call is served.

A fetch with `wait_ms` parks until a job comes or is due, or its time is up. A caller that gives up while it waits does not lose the jobs the actor had for it: they go back to the queue, and the delivery does not count.

## The conformance suite

`import Conformance from "pkg/jobs/conformance"` runs the cases that every backend must pass, so a new backend keeps the contract. Each case gets a fresh backend from your `Maker`, a function from a clock to a backend, and moves a manual clock, so no case sleeps.

```text
type Maker = Fn[Fn[Int], Result[Jobs.Backend]]
Conformance.names() -> List[String]
Conformance.run(name: String, make: Maker) -> Result[Void]
Conformance.run_all(make: Maker) -> List[Outcome]
Conformance.failed(outcomes: List[Outcome]) -> List[String]
Conformance.failures(outcomes: List[Outcome]) -> String
```

A backend package has one scenario, "the backend passes every contract case", that runs `run_all` and fails with `Conformance.failures`. A backend that moves to a newer `jobs` tag runs the new cases with no change to its specs. A backend that cannot follow an injected clock (`Caps.has_clock` false, as a database that uses its own time) gets the real clock: its time cases sleep, with a unit of half a second, and check what holds a little before and a little after a time, not to the millisecond. A case that needs a capability the backend lacks (`has_unique_keys`, `extendable`) is skipped, and its outcome says so.

```agentica
import Conformance from "pkg/jobs/conformance"
import Jobs from "pkg/jobs/jobs"

def make(clock: Fn[Int]) -> Result[Jobs.Backend] = Jobs.memory(Jobs.MemoryOptions(clock: some(clock)))

def main() -> Void
  outcomes = Conformance.run_all(&make)
  puts("cases: #{outcomes.size}")
  puts("failed: #{Conformance.failed(outcomes)}")
end
```

```output
cases: 23
failed: []
```

The cases cover: the job as it was enqueued, byte for byte; empty queues and queues that do not see each other; a fetch that waits, for a job that comes and for a job that is due; leases that run out, a late ack, nack or extend with an old token, and the same calls after the lease ran out but before any other fetch; ack, retry, release and dead; the last attempt; extend, and the job that comes back at the new end; a job that is not delivered early; unique keys, held through a retry, a release and an expired lease, and two jobs of one batch with one key; `enqueue_all` with a job that is not valid; eight tasks that fetch 200 jobs at once, each delivered once; and the calls after `close`.

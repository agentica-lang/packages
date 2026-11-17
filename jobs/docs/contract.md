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
2. **One live lease.** While a lease is live, no fetch gets that job. A new delivery has a new `token`, and ack, nack and extend with the old token fail with `jobs.lease_lost`. A lease is over at its `expires_at_ms`: a call at exactly that time finds it expired, and one a millisecond before finds it live.
3. **Not early.** No job is delivered before its `run_at_ms`.
4. **Attempts count at the fetch.** `attempt` is 1 on the first delivery and counts every delivery, also one whose lease ran out. A delivery past `max_attempts` does not happen: a lease that runs out on the last attempt makes the job dead, and so does a `Retry` on the last attempt. A job that crashes its consumer cannot loop forever. `Release` does not count.
5. **Unique keys.** While a job with the same queue and `unique_key` is ready, scheduled or leased, `enqueue` gives its id with `duplicate: true`. The key is free when the job is acked or dead.
6. **`enqueue_all` is all or nothing:** a job that is not valid, or that does not fit, fails the call and adds none. A backend writes the batch in one transaction, or in one step of its owner, so no caller sees part of it.
7. **`last_error`.** A `Retry` that carries an error makes it the `last_error` of the next delivery, a `Retry` with no error keeps the previous one, and a dead job keeps its error (the one of the `Dead`, of the last `Retry`, or why it ran out of attempts or lease). Version 1 has no call that reads a dead job, so a caller cannot observe that last part: only `test/store_test.agc` checks it, for the memory store, and the conformance suite does not.
8. **`close`** refuses new calls with `jobs.closed` and waits up to `drain_ms` for the backend to stop. Closing twice does nothing. A fetch that waits when `close` runs ends with `jobs.closed`.
9. **Groups.** A job may have a `group`, a name in its queue. A fetch with `max_per_group` above 0 never takes a job of a group that already has that many live leases in the queue: it leaves the job where it is and takes the next ready one, so a full group does not hold back the jobs behind it, and the leases of the fetch itself count. `max_per_group: 0` is no limit, and a job with no group is never limited. A lease is live from the fetch until an ack, a nack of any kind or its expiry (a `Release` and a `Retry` too), and a fetch that waits for a full group is woken when one ends. `max_per_group` below 0 and an empty `group` fail with `argument`.

There is no order guarantee. Ready jobs come roughly by `run_at_ms`, then by insertion. Acked jobs are deleted, and dead jobs are kept (the memory backend keeps `max_dead` of them). The payload is bytes: every store holds bytes, and `Jobs.json` is the typed form on top.

Times are Unix milliseconds. A backend takes a clock option (`Fn[Int]`) and defaults to the wall clock, which a database also stores. The wall clock can jump: a jump forward ends leases early, and at-least-once still holds.

## The memory backend

`Jobs.memory(Jobs.MemoryOptions(...))` keeps the jobs in one actor. `max_jobs` (10 000) is how many live jobs it holds: past it `enqueue` fails with `jobs.full`, and a producer decides to log, drop or answer 503. `max_dead` (1 000) is how many dead jobs it keeps; the oldest is dropped. `clock` is the time source. Two behaviors are the memory backend's own, not the contract's, and the conformance suite does not check them: a job that a caller that gave up would have got goes back to the queue without counting an attempt, and a fetch that waits also ends at `wait_ms` of real time. `specs/memory.feature` tests both ("A job that a caller that gave up would have got stays in the queue" and "A fetch that waits ends at its wait_ms of real time"). Every call applies the clock first, so a lease that ran out is back before the call is served.

A fetch with a limit per group passes over a full group in one step, whatever its backlog, so it costs the number of full groups, not of their jobs; a fetch that waits for a full group is asked again only when a job comes or comes due, or a lease ends. A fetch with `wait_ms` parks until a job comes or is due, or its time is up: `wait_ms` on the clock of the backend, and also `wait_ms` of real time, so on a manual clock that nobody moves a fetch still ends with `ok([])`. `fetch_timeout_ms` is the longest a caller waits for a fetch, its wait included (the default is `wait_ms` and 10 s more); a caller that gives up with `jobs.timeout` leaves its fetch parked for one more second at most, and a job that the fetch gets goes back to the queue. `fetch_timeout_ms` must be at least 1. A caller that gives up while it waits does not lose the jobs the actor had for it: they go back to the queue, and the delivery does not count.

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

A backend package has one scenario, "the backend passes every contract case", that runs `run_all` and fails with `Conformance.failures`. A backend that cannot follow an injected clock (`Caps.has_clock` false, as a database that uses its own time) gets the real clock: its time cases sleep, with a unit of one second, and check what holds a little before and a little after a time, not to the millisecond. `has_clock` is the only capability: every guarantee above, unique keys and `extend` included, is required of every backend, so a store that has no unique index or no way to move a lease keeps them in its own code, or does not fill the contract.

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
cases: 39
failed: []
```

The cases cover: the `last_error` of a retry, the job as it was enqueued, byte for byte; empty queues and queues that do not see each other; a fetch that waits, for a job that comes and for a job that is due; leases that run out, a late ack, nack or extend with an old token, and the same calls after the lease ran out but before any other fetch; ack, retry, release and dead; the last attempt; extend, and the job that comes back at the new end; a job that is not delivered early; unique keys, held through a retry, a release and an expired lease, free again when the job dies on its last attempt by expiry or by a retry, and two jobs of one batch with one key; a lease that is over at exactly its end and not a millisecond before; the groups: a full group skipped while the jobs of the others are served, kept apart by queue, freed by an ack, a retry, a release, a dead job and an expiry, woken from a fetch that waits, and a limit of 0 or a job with no group that is never held back; `enqueue_all` with a job that is not valid; eight tasks that fetch 200 jobs at once, each delivered once; the calls after `close`, and a second `close`; and a fetch that waits when the backend is closed, which ends with `jobs.closed`.

## For the author of a backend

A backend package tests itself with the suite, in BDD first: one scenario runs every case, and a new case of a newer `jobs` tag needs no change in the package.

```gherkin
Scenario: The backend passes every contract case
  When the suite runs on the backend
  Then no case failed
```

```agentica {mode="check"}
import BDD from "std/bdd"
import Conformance from "pkg/jobs/conformance"
import Jobs from "pkg/jobs/jobs"

private

FAILED = "failed"

def make(clock: Fn[Int]) -> Result[Jobs.Backend] = Jobs.memory(Jobs.MemoryOptions(clock: some(clock)))

def main() -> Void
  BDD.run([
    BDD.step("the suite runs on the backend") do |ctx, _args|
      failed = Conformance.failed(Conformance.run_all(&make))
      BDD.set(ctx, FAILED, JSON.from(failed))
    end,
    BDD.step("no case failed") do |ctx, _args|
      failed = failed_cases(ctx)
      BDD.assert(ctx, failed.empty?, "cases failed: #{failed.join("; ")}")
    end,
  ])
end

def failed_cases(ctx: BDD.Context) -> List[String]
  JSON.decode(BDD.get(ctx, FAILED).unwrap!, List[String]).unwrap_or([])
end
```

- Each case needs a fresh, empty backend: the maker is called once for each case, and a backend that shares a database between calls must empty its tables, or use a schema of its own.
- The cases use the queue names `conformance` and `other`, and the keys and payloads that they make up. A table of the backend can hold nothing else that those names would meet.
- The maker runs in the task that calls `run_all`, so a backend that starts tasks (an actor) is a child of it and stays up while the case runs. The suite closes the backend after each case, so the maker must not close it.
- On a backend with `has_clock: false` the cases on time run on the real clock and sleep. The whole suite takes about 31 s then, and under a second on a manual clock. To time the kit alone, run `time agentica FILE` on a file whose `main` calls `Conformance.run_all` with the maker and prints `Conformance.failed` of its outcomes.

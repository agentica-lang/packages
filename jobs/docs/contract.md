---
title: The contract
description: What every jobs backend guarantees, and the records of the contract.
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

There is no order guarantee. Ready jobs come roughly by `run_at_ms`, then by insertion. Acked jobs are deleted, and dead jobs are kept. The payload is bytes: every store holds bytes, and `Jobs.json` is the typed form on top.

Times are Unix milliseconds. A backend takes a clock option (`Fn[Int]`) and defaults to the wall clock, which a database also stores. The wall clock can jump: a jump forward ends leases early, and at-least-once still holds.

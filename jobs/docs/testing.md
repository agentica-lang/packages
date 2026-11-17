---
title: Testing an app
description: Run the jobs of an app in its tests with the memory backend, a manual clock and Jobs.drain, with no sleep and no task left running.
weight: 3
---

An app test enqueues jobs, drains the queue in the test itself, and checks what the handlers did. The memory backend stands in for the backend of production, and a manual clock moves time by hand, so nothing sleeps.

`Jobs.manual_clock()` gives a `Clock`: `now` reads it and `advance(ms)` moves it. Pass `now` as the `clock` of the backend. `Jobs.drain` runs the jobs of a queue one at a time in the caller, with the rules of a pipeline: `ok` acks the job, `Jobs.discard(message)` makes it dead, and any other error runs it again after a backoff, or makes it dead on its last attempt. It gives how many jobs were acked, put back and made dead, and logs with `std/logger` a job that will run again (a `warning`) and a dead one (an `err`), with the queue, the id and the attempt.

With `due: Jobs.Due.Ready` (the default) it runs the jobs whose time has come. With `Jobs.Due.All` it also runs the ones that wait for a time, moving the manual clock that you give it in `clock`, so a retry runs too.

```agentica
import Jobs from "pkg/jobs/jobs"

def handle(job: Jobs.Job) -> Result[Void]
  text = String.from_bytes(job.payload).unwrap_or("")
  return Jobs.discard("not an address") if text == "nobody"
  return error("the server is down") if text == "ana@example.com" and job.attempt == 1

  puts("sent to #{text} on attempt #{job.attempt}")
  ok()
end

def main() -> Void
  clock = Jobs.manual_clock()
  backend = Jobs.memory(Jobs.MemoryOptions(clock: some(clock.now))).unwrap!
  for to in ["ana@example.com", "bo@example.com", "nobody"]
    _ = Jobs.enqueue(backend, Jobs.NewJob(queue: "mail", payload: to.bytes)).unwrap!
  end

  first = Jobs.drain(backend, Jobs.Drain(queue: "mail", clock: some(clock)), &handle).unwrap!
  puts(first)
  second = Jobs.drain(backend, Jobs.Drain(queue: "mail", due: Jobs.Due.All, clock: some(clock)), &handle).unwrap!
  puts(second)
  Jobs.close(backend, 1000)
end
```

```output
sent to bo@example.com on attempt 1
Drained(done: 1, retried: 1, dead: 1)
sent to ana@example.com on attempt 2
Drained(done: 1, retried: 0, dead: 0)
```

A drain moves the clock forward by two hours each time only scheduled jobs are left, which is past the longest default backoff. Give `backoff` (a function from the attempt to the wait in ms) to choose the wait.

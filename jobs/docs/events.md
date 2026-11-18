---
title: Events
description: What jobs tells the telemetry package, by name, with its measurements and metadata, and how to read it in an app test.
weight: 4
---

`jobs` says what happens to a job with the [telemetry](https://www.agentica-lang.com/packages/telemetry/) package, as `std/logger` says it in text for a person. The calls of `Jobs` (`enqueue`, `enqueue_all`, `fetch`, `ack`, `nack`) emit an event after the backend answered, so every backend gets them, and `Jobs.drain` also runs each job in a span. Nothing is emitted for a call that failed: an event says what happened. With no handler attached a call costs a few dozen steps more (one table read, and no map is built), so a program that does not use telemetry pays nothing it can see.

An app attaches the handlers, after `Telemetry.start()` in its `main`, with the names it wants (`["jobs"]` for all of them). Use the same `telemetry` tag as `jobs` does, or the manifest has two sources for one name (`PKG-SOURCE-CONFLICT`).

| Event | Measurements | Metadata |
|---|---|---|
| `jobs.enqueue` | `count` (jobs added), `duplicate_count` | `queue`, `backend` |
| `jobs.fetch` | `count` (jobs leased) | `queue`, `backend` |
| `jobs.ack` | `count` (1) | `queue`, `id`, `attempt`, `backend` |
| `jobs.nack` | `count` (1) | `queue`, `id`, `attempt`, `backend`, `how` (`retry`, `release` or `dead`) |
| `jobs.job.start` | none | `queue`, `id`, `attempt`, `backend`, `span_id` |
| `jobs.job.stop` | `duration_ns` | as `start` |
| `jobs.job.error` | `duration_ns` | as `start`, and `error_kind` |
| `jobs.job.settle` | `count` (1) | `queue`, `id`, `attempt`, `backend`, `verdict` (`ack`, `retry` or `dead`) |

- `jobs.enqueue` is one event for each queue of a batch, and a job that was a duplicate of a unique key is in `duplicate_count`, as well as in `count`.
- A fetch that leased nothing emits nothing: a consumer that polls would fill a handler with empty events. The event of a fetch that did lease has the number of jobs.
- `jobs.job.start|stop|error` are the span of the handler in `Jobs.drain`. A handler that returns an error ends in `jobs.job.error`, with the `error_kind` of that error (`jobs.discard` for `Jobs.discard`, and `error` for a plain one). The time is the time of the handler, not of the ack.
- `jobs.job.settle` is what the drain decided after the handler: `ack`, `retry` (the job runs again) or `dead` (a discard, or a failure on the last attempt). It comes after the `jobs.ack` or `jobs.nack` that carried it out.
- The metadata has ids and names, never the payload or the text of an error. The `id` is a string that the backend makes up, a good key for a trace and a bad label for a metric: keep it out of the labels of a reporter. The logger lines of a drain stay as they were, for people.
- Events of one task arrive in order, and events of different tasks have no order between them. A handler is slow or fails without hurting the consumer (see the [telemetry docs](https://www.agentica-lang.com/packages/telemetry/)); the events it cannot take are counted by `Telemetry.dropped`.

## Read them in a test

`Testing.session` of `telemetry` captures the events of a block and leaves no task running, so it fits in a test of an app. This one drains a queue and reads what `jobs` said.

```agentica
import Jobs from "pkg/jobs/jobs"
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

def handle(job: Jobs.Job) -> Result[Void]
  return Jobs.discard("not an address") if job.attempt == 1

  ok()
end

def line(event: Telemetry.Event) -> String
  extra = event.metadata.get("error_kind", event.metadata.get("verdict", event.metadata.get("how", "")))
  return event.name if extra == ""

  "#{event.name} #{extra}"
end

def drain_one(backend: Jobs.Backend, capture: Testing.Capture) -> Result[List[String]]
  _ = Jobs.enqueue(backend, Jobs.NewJob(queue: "mail", payload: "nobody".bytes)).unwrap!
  _ = Jobs.drain(backend, Jobs.Drain(queue: "mail"), &handle)
  found = try Testing.events(capture)
  ok(found.map(&line))
end

def main() -> Void
  backend = Jobs.memory().unwrap!
  for text in Testing.session(["jobs"], ->(capture) { drain_one(backend, capture) }).unwrap!
    puts(text)
  end

  Jobs.close(backend, 1_000)
end
```

```output
jobs.enqueue
jobs.fetch
jobs.job.start
jobs.job.error jobs.discard
jobs.nack dead
jobs.job.settle dead
```

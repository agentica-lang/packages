---
title: Conventions
description: How to name events and their measurements, so that a library and a reporter agree without talking to each other.
weight: 2
---

An event is a contract between the library that emits it and the handlers that read it. These rules keep the names alike across libraries, so that a reporter can turn an event into a metric from its name and its keys alone.

## Names

- A name is dotted words of `a` to `z`, digits and `_`, from one to four.
- The first word is the package, with `-` turned into `_`: `jobs`, `pool`, `http_client`.
- The rest says what happened, from the whole to the part: `jobs.job.stop`, `pool.checkout.stop`, `http_client.request.error`.
- A name is a thing that is true when it is heard, not an instruction: `jobs.enqueue`, not `jobs.do_enqueue`.
- Something that takes time has an event for each end: `.start`, then `.stop` when it worked or `.error` when it returned an error. Only `.stop` and `.error` have `duration_ns`.

## Measurements

Put a whole number in `ints` and a number with a fraction in `floats`. A key has a unit as its suffix, and the same key is never in both maps.

| Key | Map | Means |
|---|---|---|
| `count`, `..._count` | `ints` | how many things this event is about, or how many of one kind: `attempt_count`, `idle_count`, `in_use_count`, `running_count` |
| `duration_ns` (any `..._ns`) | `ints` | how long, in nanoseconds (`Time.monotonic_ns` gives them) |
| `size_bytes` (any `..._bytes`) | `ints` | how big, in bytes |
| `size`, `..._size` | `ints` | how many items a thing holds now (a gauge): `size`, `run_queue_size` |
| `ratio`, `..._ratio` | `floats` | a fraction from 0.0 to 1.0: `utilization_ratio`, `load_ratio` |
| `..._per_second` | `floats` | a rate: `tasks_per_second` |
| `..._total` | `ints` | a total since the start of the process, only in a snapshot that something else keeps: `pauses_total` |

An event is either a delta, one thing that happened (`count`, `duration_ns`), or a reading of a gauge (`size`). A reporter that sums deltas gets a counter, and one that keeps the last reading gets a gauge. A total is for a snapshot, where the sender keeps the sum.

Durations are in nanoseconds and sizes in bytes, and reporters convert: a handler that wants seconds divides, and the emitter never does. A duration is always an integer `_ns`, never a float of seconds.

## Metadata

Metadata says which one it was. `span_id` (which `Telemetry.span` adds) is for matching the events of one span, never for a label of a reporter: each span has its own. Its keys are `snake_case` words, and its values are short strings of a fixed set: a queue, a pool, a status class. Do not put a secret in it, or a value that has no end (a user id, a URL with its query): a reporter that makes a label of each value would make millions of them. An id is allowed when it is for a person who reads a log, and a reporter must then choose its labels from a list.

## In a library

A library depends on `telemetry` pinned by a tag, the same tag as the apps that use it, or the app gets `PKG-SOURCE-CONFLICT`. It calls `execute` where the thing happens and does not start the hub, attach handlers or call `flush`: the app does.

```agentica
import Telemetry from "pkg/telemetry/telemetry"

# A handler that counts: an `ATS` table takes the sums of many tasks without a lock.
struct Totals
  counts: ATS[String, Int]
end

def send_mail(queue: String) -> Result[Void]
  started = Time.monotonic_ns
  Task.sleep(2)
  Telemetry.execute(
    "mailer.send.stop",
    ints: {"duration_ns": Time.monotonic_ns - started, "size_bytes": 2_048},
    metadata: {"queue": queue},
  )

  ok()
end

def tally(totals: Totals, event: Telemetry.Event) -> Result[Void]
  _ = totals.counts.add("#{event.name} #{event.metadata.get("queue", "")}", 1)
  _ = totals.counts.add("bytes", event.ints.get("size_bytes", 0))
  ok()
end

def main() -> Void
  totals = Totals(counts: ATS.new())
  Telemetry.start().unwrap!
  Telemetry.attach("tally", ["mailer"], ->(event) { tally(totals, event) }).unwrap!
  send_mail("welcome").unwrap!
  send_mail("welcome").unwrap!
  send_mail("reset").unwrap!
  Telemetry.flush().unwrap!
  puts(totals.counts.to_map())
  Telemetry.stop().unwrap!
end
```

```output
{"mailer.send.stop welcome": 2, "bytes": 6144, "mailer.send.stop reset": 1}
```

## Check the events in a test

`Conformance.check(event)` is for the tests of a library: it gives `ok` for an event that follows these rules, and an error with a problem for one that does not. Collect what the library emits with a handler that keeps the events, and check each. It checks:

- the name: one to four words (`conformance.name`);
- each measurement key: a unit that says what it is (`count`, `size`, or a name that ends in `_count`, `_size`, `_ns`, `_bytes` or `_total` in `ints`; `ratio`, or a name that ends in `_ratio` or `_per_second` in `floats`), so in one map only, and `duration_ns` only on a `.stop` or `.error` event (`conformance.measurement`);
- each metadata key: a `snake_case` word (`conformance.metadata`).

```agentica
import Conformance from "pkg/telemetry/conformance"
import Telemetry from "pkg/telemetry/telemetry"

def check(name: String, ints: Map[String, Int]) -> Void
  event = Telemetry.Event(name: name, ints: ints, metadata: {"queue": "mail"})
  case Conformance.check(event)
    ok(_) -> puts("#{name}: ok")
    error(e) -> puts("#{name}: #{e.kind}")
  end
end

def main() -> Void
  check("jobs.job.stop", {"duration_ns": 40_000})
  check("jobs.job.start", {"duration_ns": 0})
  check("Jobs.job.stop", {})
  check("jobs.fetch", {"waiting": 3})
end
```

```output
jobs.job.stop: ok
jobs.job.start: conformance.measurement
Jobs.job.stop: conformance.name
jobs.fetch: conformance.measurement
```

The events of a library are part of its API: a rename is a breaking change, and the CHANGELOG lists the events with their keys.

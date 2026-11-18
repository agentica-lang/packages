---
title: telemetry
description: Events for numbers, as std/logger is for text. A library says that something happened, and an app attaches handlers to count it, log it or send it away. A call with no handler costs almost nothing, and a handler can never hurt the code that emits.
---

`telemetry` is for the numbers of a program: how long a job took, how many were retried, how many connections a pool has. A library calls `Telemetry.execute` to say that something happened, and does not decide where the number goes. The app attaches a handler that counts it, logs it or sends it to a monitor.

`std/logger` is for text that a person reads. An event of `telemetry` is data for a program: a name, numbers and a few strings.

Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir` (the first tag will be `telemetry-0.1.0`):

```sh
agentica add telemetry https://github.com/agentica-lang/packages --tag telemetry-0.1.0 --subdir telemetry
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
telemetry = { git = "https://github.com/agentica-lang/packages", tag = "telemetry-0.1.0", subdir = "telemetry" }
```

## An example

Start the hub once, in `main`. A handler is a function from an event to a `Result[Void]`, attached under an id to the events it wants.

```agentica
import Telemetry from "pkg/telemetry/telemetry"

def show(event: Telemetry.Event) -> Result[Void]
  puts("#{event.name} #{event.ints} #{event.metadata}")
  ok()
end

def main() -> Void
  Telemetry.start().unwrap!
  Telemetry.attach("show", ["jobs"], &show).unwrap!
  Telemetry.execute("jobs.job.stop", ints: {"duration_ns": 1_200_000}, metadata: {"queue": "mail"})
  Telemetry.execute("pool.checkout.stop", ints: {"duration_ns": 40})
  Telemetry.flush().unwrap!
  Telemetry.stop().unwrap!
end
```

```output
jobs.job.stop {"duration_ns": 1200000} {"queue": "mail"}
```

The handler heard `jobs.job.stop` and not `pool.checkout.stop`. `flush` waits until the handlers have handled what was emitted before it: delivery is async, so a program or a test calls it before it reads what a handler did, or before it ends.

## An event

An event has:

- `name`: a dotted name such as `jobs.job.stop` (the [conventions](conventions.md) say how to choose one);
- `ints`: a `Map[String, Int]` for the counts, the durations (`duration_ns`) and the sizes (`size_bytes`);
- `floats`: a `Map[String, Float]` for the fractions and ratios;
- `metadata`: a `Map[String, String]` that says which one it was (`queue`, `pool`);
- `time_ms`: the wall clock when `execute` ran, and `task`: the id of the task that called it.

There are two maps of measurements because the type tells a handler what it can do with a number. Integers are exact and `ATS.add` sums them atomically, so a counter that many tasks update needs no lock; a float is for a number that is not whole. The names say the type (`ints` and `floats`) and not the meaning, since a count, a duration and a size are all integers: the meaning is in the key, with its unit as a suffix. A key is in one map only.

## Choosing the events

`attach(id, events, handler)` takes a list of patterns. A pattern is an event name, or the start of one at a dot: `"jobs"` hears `jobs`, `jobs.job` and `jobs.job.stop`, and not `jobs_extra.stop` or `job`. `"*"` hears every event. A handler with several patterns that match one event hears it once. A pattern is one to four words of `a` to `z`, digits and `_` joined by dots, or `*`; anything else is an `argument` error.

`execute` never fails, never waits and never checks its name. An event whose name is not valid is heard only by `"*"`.

```agentica
import Telemetry from "pkg/telemetry/telemetry"

def count(event: Telemetry.Event) -> Result[Void] = ok()

def main() -> Void
  Telemetry.start().unwrap!
  puts(Telemetry.enabled?("jobs.job.stop"))
  Telemetry.attach("count", ["jobs.job"], &count).unwrap!
  puts(Telemetry.enabled?("jobs.job.stop"))
  puts(Telemetry.enabled?("jobs.enqueue"))
  puts(Telemetry.handlers())
  Telemetry.detach("count").unwrap!
  puts(Telemetry.handlers())
  Telemetry.stop().unwrap!
end
```

```output
false
true
false
["count"]
[]
```

`enabled?` says whether an `execute` of a name reaches a handler. With no handler attached, `execute` costs one table read, so a library can emit everywhere; guard with `enabled?` only an event whose arguments cost something to build.

## Slow and broken handlers

Each handler runs in an actor of its own, with a queue of `Options.capacity` events (1024 by default). `execute` puts the event in the queue of each handler that hears it and goes on, so a slow handler delays only itself. When a queue is full the newest event is dropped, and `Telemetry.dropped(id)` counts it. Events of one emitter reach a handler in order; events of different tasks have no order between them.

```agentica
import Telemetry from "pkg/telemetry/telemetry"

def stuck(event: Telemetry.Event) -> Result[Void]
  Task.sleep(300)
  ok()
end

def main() -> Void
  Telemetry.start().unwrap!
  Telemetry.attach("slow", ["tick"], &stuck, Telemetry.Options(capacity: 1)).unwrap!
  for i in 1..10
    Telemetry.execute("tick.n", ints: {"i": i})
  end

  puts("the emitter did not wait")
  puts(Telemetry.dropped("slow") >= 8)
  Telemetry.stop().unwrap!
end
```

```output
the emitter did not wait
true
```

A handler that returns an error, or crashes, is detached at once: its actor ends and its routes go. The hub writes one `Logger.warning` with the id and the kind of the error (or the `RUNTIME-` code of the crash), and nothing of the event. The other handlers and the emitter are not affected. After a `flush`, a handler that failed on an earlier event is already detached, and its id is free again.

```agentica
import Telemetry from "pkg/telemetry/telemetry"

def fussy(event: Telemetry.Event) -> Result[Void] = error("no thanks", kind: "fussy.no")

def main() -> Void
  Telemetry.start().unwrap!
  Telemetry.attach("fussy", ["tick"], &fussy).unwrap!
  Telemetry.execute("tick.a")
  Telemetry.flush().unwrap!
  puts(Telemetry.handlers())
  Telemetry.stop().unwrap!
end
```

```output
[]
```

A crash prints its diagnostic on stderr, as any crash of a task does, and does not fail the run: the hub watches the handler, so it is observed.

## The API

```text
Telemetry.start() -> Result[Void]
Telemetry.stop(timeout_ms: Int = 5000) -> Result[Void]
Telemetry.execute(name: String, ints: Map[String, Int] = {}, floats: Map[String, Float] = {},
  metadata: Map[String, String] = {}) -> Void
Telemetry.enabled?(name: String) -> Bool
Telemetry.attach(id: String, events: List[String], handler: Fn[Telemetry.Event, Result[Void]],
  options: Telemetry.Options = Telemetry.Options()) -> Result[Void]
Telemetry.detach(id: String) -> Result[Void]
Telemetry.handlers() -> List[String]
Telemetry.dropped(id: String) -> Int
Telemetry.flush(timeout_ms: Int = 5000) -> Result[Void]
```

- `start` starts the hub, an actor that is the only task that changes the handlers; it is a child of the task that calls it, so call it in `main`. Emitters read the routes without asking the hub. Before `start`, `execute` does nothing and `attach` fails.
- `stop` drains the handlers (as `flush`), detaches them all and ends the hub. A test that shares a process with others calls `stop` at its end and `start` at its beginning.
- `detach` removes a handler at once: the events in its queue are not delivered.
- Errors have a kind: `telemetry.not_started`, `telemetry.started`, `telemetry.duplicate` (the id is in use), `telemetry.unknown` (`detach` of an id that is not attached), `telemetry.timeout` (`flush` or `stop` ran out of time), and `argument` for a bad id, pattern or capacity.

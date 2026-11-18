---
title: Testing
description: Assert on the events that code emits, in an app test or in a library's own tests, with a helper that captures them, flushes before it reads, and never sleeps. Check them against the conventions with Conformance.check.
weight: 3
---

Events are delivered by the handlers' own actors, after `execute` has returned. A test that reads what a handler got right after the call can read too early. The rule is: **flush before you read**. `Telemetry.flush` waits until every handler has handled what was emitted before it, with no sleep and no guess. The helper `telemetry/testing` does the flush for you.

```agentica {mode="fragment"}
import Testing from "pkg/telemetry/testing"
```

## Assert on the events of an app

`Testing.session(patterns, body)` starts a hub when none runs, attaches a capture for `patterns` (as `Telemetry.attach` takes them), runs `body` with the capture, and then detaches it and ends the hub and its tasks. `Testing.events(capture)` flushes and gives the events emitted since the last read, in order. The session leaves no task running, so it fits in a unit test or a single step of a BDD feature.

```agentica
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

def send_mail(queue: String) -> Result[Void]
  Telemetry.execute("mailer.send.stop", ints: {"size_bytes": 2_048}, metadata: {"queue": queue})
  ok()
end

def sends_one_event(capture: Testing.Capture) -> Result[String]
  send_mail("welcome").unwrap!
  found = try Testing.events(capture)
  event = found[0]
  ok("#{found.size} event: #{event.name} #{event.ints} #{event.metadata}")
end

def main() -> Void
  puts(Testing.session(["mailer"], &sends_one_event).unwrap!)
end
```

```output
1 event: mailer.send.stop {"size_bytes": 2048} {"queue": "welcome"}
```

`events` gives what came since the previous call, so a test can read after each step of the code under test:

```agentica
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

def names(capture: Testing.Capture) -> Result[List[String]]
  found = try Testing.events(capture)
  ok(found.map(->(event) { event.name }))
end

def steps(capture: Testing.Capture) -> Result[Void]
  Telemetry.execute("jobs.enqueue")
  Telemetry.execute("jobs.fetch")
  puts(try names(capture))
  Telemetry.execute("jobs.job.stop", ints: {"duration_ns": 40})
  puts(try names(capture))
  puts(try names(capture))
  ok()
end

def main() -> Void
  Testing.session(["jobs"], &steps).unwrap!
end
```

```output
["jobs.enqueue", "jobs.fetch"]
["jobs.job.stop"]
[]
```

The events of one task arrive in the order it emitted them. Events of different tasks have no order between them, so a test that emits from many tasks should sort or count, not compare a list.

## Test the events of a library

A library checks its own events in its tests: capture what a call emits, and give each event to `Conformance.check` (see the [conventions](conventions.md)), so the names, units and keys stay as the docs say. Then assert on what the library promises.

```agentica
import Conformance from "pkg/telemetry/conformance"
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

def fetch(queue: String) -> Result[Int]
  Telemetry.span("jobs.fetch", {"queue": queue}) do ok(3) end
end

def follows_the_conventions(capture: Testing.Capture) -> Result[Void]
  fetch("mail").unwrap!
  for event in try Testing.events(capture)
    case Conformance.check(event)
      ok(_) -> puts("#{event.name}: ok")
      error(e) -> puts("#{event.name}: #{e.message}")
    end
  end

  ok()
end

def main() -> Void
  Testing.session(["jobs"], &follows_the_conventions).unwrap!
end
```

```output
jobs.fetch.start: ok
jobs.fetch.stop: ok
```

## A program that owns the hub

When the app already started the hub in `main`, use `capture` and `stop` yourself, and `session` also works: it uses the running hub and leaves it running. `stop(capture)` detaches the handler; read the events first, since the ones not read are gone.

```agentica
import Telemetry from "pkg/telemetry/telemetry"
import Testing from "pkg/telemetry/testing"

def main() -> Void
  Telemetry.start().unwrap!
  capture = Testing.capture(["pool"]).unwrap!
  Telemetry.execute("pool.checkout.stop", ints: {"duration_ns": 900})
  puts(Testing.events(capture).unwrap!.map(->(event) { event.name }))
  Testing.stop(capture).unwrap!
  puts(Telemetry.handlers())
  Telemetry.stop().unwrap!
end
```

```output
["pool.checkout.stop"]
[]
```

## When events do not fit

A capture has room for 4096 events between two reads (`capture(patterns, room)` changes it). A test that emits more and does not read gets the error `telemetry.lost` from `events`, with the number, and not a list with a hole in it: raise `room`, or read more often.

## In a BDD feature

A step cannot leave a task running, and the hub and the handlers are tasks. There are two ways:

- Run the whole test in one step: `Testing.session` starts the hub, captures, runs your body and ends everything before it returns, so a step can emit, read and assert in itself. This is how the specs of this package test the helper.
- Or keep the code under test in a driver program that the steps talk to by JSON lines, as the `jobs` specs do, and call `Testing.capture` and `Testing.events` in the driver.

A test never needs `Task.sleep` for an event: `events` and `flush` wait exactly as long as needed, and give `telemetry.timeout` when a handler is stuck.

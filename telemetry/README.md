# telemetry

Events for numbers, as `std/logger` is for text: a library calls `Telemetry.execute` to say that something happened (a
name, integer and float measurements, string metadata), and an app attaches handlers to count it, log it or send it
away. A call with no handler costs one table read. Each handler runs in an actor with a bounded queue, so a slow or
broken handler never hurts the code that emits: a full queue drops the newest event and counts it, and a handler that
fails is detached with one warning.

Add it in a project with an `agentica.toml`:

```sh
agentica add telemetry https://github.com/agentica-lang/packages --tag telemetry-0.1.0 --subdir telemetry
```

The docs, with the example and the naming conventions: <https://www.agentica-lang.com/packages/telemetry/>.

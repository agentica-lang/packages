# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.34.1.

### Added

- `Telemetry.start` and `Telemetry.stop`: the hub, an actor that is the only writer of the handlers.
- `Telemetry.execute`: an event with a dotted name, `ints`, `floats` and `metadata`, that never fails or waits and costs one table read with no handler attached; `Telemetry.enabled?` says whether a name has a handler.
- `Telemetry.attach` and `Telemetry.detach`: handlers by id, for patterns that match a name or its start at a dot, and `"*"`; `Telemetry.handlers` lists them.
- Each handler runs in an actor with a bounded queue (`Options.capacity`): a full queue drops the newest event, which `Telemetry.dropped` counts, and `Telemetry.flush` waits until the handlers have handled what was emitted before it.
- A handler that returns an error or crashes is detached, with one `Logger.warning` that has the id and the kind and nothing of the event.
- `Telemetry.flush` and `Telemetry.stop` give `telemetry.in_handler` when a handler calls them; a hub that ended with the task that started it is replaced by the next `Telemetry.start`, and several starts at once give one hub.
- `Telemetry.span`: runs a body and emits `NAME.start`, then `NAME.stop` with `duration_ns`, or `NAME.error` with `duration_ns` and `error_kind`, all with one `span_id`; when no handler hears it, it only calls the body.
- `Conformance.check` (`telemetry/conformance`): a check of an event against the naming, unit (`count`, `size`, `_count`, `_size`, `_ns`, `_bytes`, `_total` for integers; `ratio`, `_ratio`, `_per_second` for floats) and metadata conventions, for the tests of a library.
- `Testing.capture`, `Testing.events`, `Testing.stop` and `Testing.session` (`telemetry/testing`): a capture of the events that match, read after a `flush` and without a sleep, and a session that leaves no task running, for the tests of an app, a library or a BDD step.
- Naming and unit conventions and a testing page, in the docs.

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
- Naming and unit conventions, in the docs.

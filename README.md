# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; install one with `subdir` and its prefixed tag:

```toml
[dependencies]
cache = { git = "https://github.com/agentica-lang/packages", tag = "cache-0.1.0", subdir = "cache" }
```

| Package | What it is |
|---|---|
| `bond-channels` (in progress) | Action Cable (`actioncable-v1-json`) channels for Bond apps: one WebSocket per tab at `/cable`, channels and a pub/sub hub. The frames, the hub, the connections and the Turbo Streams signing are in (`bond-channels/channels.agc`). [#1](https://github.com/agentica-lang/packages/issues/1) has the plan |
| `prop` (in progress) | Property-based testing: generators, shrinking, `Prop.check`, which runs a law on generated inputs and reports the smallest counterexample with its seed, law helpers, `Prop.of` for your types and a bounded exhaustive check. [#12](https://github.com/agentica-lang/packages/issues/12) has the plan |
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

## Tags

A tag is `PACKAGE-X.Y.Z`, where `PACKAGE` is the folder name (`cache-0.1.0`, `bond-channels-0.1.0`), so each package has its own versions. The `tag` of a dependency is that name, and `subdir` is the folder.

## Docs

The docs are at <https://agentica-lang.github.io/packages/>. Each package keeps its pages in its own `PACKAGE/docs/` folder (an `_index.md` at least), and `make site` builds them into one Hugo site in `site/public` (Hugo and Node are needed; `make site-serve` previews it).

Rules for contributors and agents: `AGENTS.md`.

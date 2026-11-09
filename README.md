# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; add one with its prefixed tag and its folder as `--subdir`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.1.0 --subdir prop
```

It writes the line of `agentica.toml` and the entry of `agentica.lock`, and fetches the package:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.1.0", subdir = "prop" }
```

| Package | What it is |
|---|---|
| `bond-channels` (`bond-channels-0.2.1`) | Action Cable (`actioncable-v1-json`) channels for Bond apps: one WebSocket per tab at `/cable`, channels and a pub/sub hub, with the frames, the connections and the Turbo Streams signing (`bond-channels/channels.agc`). [Docs](https://agentica-lang.github.io/packages/bond-channels/) |
| `prop` (`prop-0.1.0`) | Property-based testing: generators, shrinking, `Prop.check`, which runs a law on generated inputs and reports the smallest counterexample with its seed, law helpers, `Prop.of` for your types and a bounded exhaustive check. [Docs](https://agentica-lang.github.io/packages/prop/) |
| `native-gen` (`native-gen-0.1.0`) | The C header of an `extern module` block: typed prototypes, the argument checks, the codecs and the tables of the module, generated from the `.agc`, and `new` to start a module. [Docs](https://agentica-lang.github.io/packages/native-gen/) |
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

## Tags

A tag is `PACKAGE-X.Y.Z`, where `PACKAGE` is the folder name (`cache-0.1.0`, `bond-channels-0.1.0`), so each package has its own versions. The `tag` of a dependency is that name, and `subdir` is the folder.

## Docs

The docs are at <https://agentica-lang.github.io/packages/>. Each package keeps its pages in its own `PACKAGE/docs/` folder (an `_index.md` at least), and `make site` builds them into one Hugo site in `site/public` (Hugo and Node are needed; `make site-serve` previews it).

Rules for contributors and agents: `AGENTS.md`.

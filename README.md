# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; add one with its prefixed tag and its folder as `--subdir`, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.4.1 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.4.1", subdir = "prop" }
```

| Package | What it is |
|---|---|
| `bond-channels` (`bond-channels-0.5.0`) | Action Cable (`actioncable-v1-json`) channels for Bond apps: one WebSocket per tab at `/cable`, channels and a pub/sub hub, with the frames, the connections and the Turbo Streams signing (`bond-channels/channels.agc`). [Docs](https://agentica-lang.github.io/packages/bond-channels/) |
| `prop` (`prop-0.4.1`) | Property-based testing: generators, shrinking, `Prop.check`, which runs a law on generated inputs and reports the smallest counterexample with its seed, law helpers, `Prop.of` for your types and a bounded exhaustive check. [Docs](https://agentica-lang.github.io/packages/prop/) |
| `native-gen` (`native-gen-0.4.0`) | The C header of an `extern module` block: typed prototypes, the argument checks, the codecs and the tables of the module, generated from the `.agc`, and `new` to start a module. [Docs](https://agentica-lang.github.io/packages/native-gen/) |
| `dock` (`dock-0.3.0`) | A TCP server: an accept loop, a task per client that runs your handler, and the clean-up when a client ends or crashes (`dock/dock.agc`). [Docs](https://agentica-lang.github.io/packages/dock/) |
| `pool` (`pool-0.1.2`) | A generic pool of resources in the style of NimblePool: long-lived resources lent to one caller at a time, with a line, a lease, a health tick and a close with a drain; a caller that ends never keeps its resource (`pool/pool`). [Docs](https://agentica-lang.github.io/packages/pool/) |
| `websocket-client` (`websocket-client-0.3.0`) | A WebSocket client (RFC 6455) over `std` TCP and TLS: `ws://` and `wss://`, text and binary messages, fragments, pings, the close handshake, a size limit and a read timeout (`websocket-client/websocket`). [Docs](https://agentica-lang.github.io/packages/websocket-client/) |
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

## Tags

A tag is `PACKAGE-X.Y.Z`, where `PACKAGE` is the folder name (`prop-0.1.0`, `bond-channels-0.1.0`), so each package has its own versions. A release that needs a pre-release of Agentica is a pre-release too (`prop-0.3.0-alpha.1` needs Agentica 0.31.0-alpha.1). The `tag` of a dependency is that name, and `subdir` is the folder.

## Agentica versions

Each package needs its own Agentica version, written in `PACKAGE/AGENTICA_VERSION` (the version, then the sha256 of its `linux-x86_64` archive); the CHANGELOG of the package says when it changed. CI and the Makefile run each package on that version.

## Docs

The docs are at <https://agentica-lang.github.io/packages/>. Each package keeps its pages in its own `PACKAGE/docs/` folder (an `_index.md` at least), and `make site` builds them into one Hugo site in `site/public` (it needs the docs theme, `git submodule update --init`, plus Hugo, Dart Sass and Node; `make site-serve` previews it).

Rules for contributors and agents: `AGENTS.md`.

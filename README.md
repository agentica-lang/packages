# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; add one with its prefixed tag and its folder as `--subdir`, in a project with an `agentica.toml`:

```sh
agentica add prop https://github.com/agentica-lang/packages --tag prop-0.4.2 --subdir prop
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
prop = { git = "https://github.com/agentica-lang/packages", tag = "prop-0.4.2", subdir = "prop" }
```

| Package | What it is |
|---|---|
| `bond-channels` (`bond-channels-0.6.2`) | Action Cable (`actioncable-v1-json`) channels for Bond apps: one WebSocket per tab at `/cable`, channels and a pub/sub hub, with the frames, the connections and the Turbo Streams signing (`bond-channels/channels.agc`). [Docs](https://www.agentica-lang.com/packages/bond-channels/) |
| `prop` (`prop-0.4.2`) | Property-based testing: generators, shrinking, `Prop.check`, which runs a law on generated inputs and reports the smallest counterexample with its seed, law helpers, `Prop.of` for your types and a bounded exhaustive check. [Docs](https://www.agentica-lang.com/packages/prop/) |
| `native-gen` (`native-gen-0.4.0`) | The C header of an `extern module` block: typed prototypes, the argument checks, the codecs and the tables of the module, generated from the `.agc`, and `new` to start a module. [Docs](https://www.agentica-lang.com/packages/native-gen/) |
| `dock` (`dock-0.3.0`) | A TCP server: an accept loop, a task per client that runs your handler, and the clean-up when a client ends or crashes (`dock/dock.agc`). [Docs](https://www.agentica-lang.com/packages/dock/) |
| `http-client` (`http-client-0.1.0`) | An HTTP/1.1 client in the spirit of Req: a pool of keep-alive connections per origin on `pool`, `base_url`, client headers and params, JSON bodies, auth, gzip and deflate decoding, request and response steps, streamed bodies and server-sent events, retries, redirects, and timeouts for the connect, each read, the whole request and the wait for a connection (`http-client/http_client`). [Docs](https://www.agentica-lang.com/packages/http-client/) |
| `pool` (`pool-0.1.3`) | A generic pool of resources in the style of NimblePool: long-lived resources lent to one caller at a time, with a line, a lease, a health tick and a close with a drain; a caller that ends never keeps its resource (`pool/pool`). [Docs](https://www.agentica-lang.com/packages/pool/) |
| `websocket-client` (`websocket-client-0.3.0`) | A WebSocket client (RFC 6455) over `std` TCP and TLS: `ws://` and `wss://`, text and binary messages, fragments, pings, the close handshake, a size limit and a read timeout (`websocket-client/websocket`). [Docs](https://www.agentica-lang.com/packages/websocket-client/) |
| `jobs` (unreleased) | Produce and consume jobs with a swappable backend: the contract of a backend, with leases, retries with a time, unique keys and dead jobs (`jobs/jobs`). [Docs](https://www.agentica-lang.com/packages/jobs/) |
| `yaml` (unreleased) | A YAML 1.2 parser: one document or a stream to `JSON.Value`, with the core schema only, string keys, limits on depth, aliases and size, and errors with a line and a column (`yaml/yaml`). [Docs](https://www.agentica-lang.com/packages/yaml/) |
| `dns` (`dns-0.1.0`) | A DNS client: queries over TCP, TLS and HTTPS to the nameservers you choose, tried in order, with CNAMEs followed, addresses with their TTLs, distinct errors, and a bounded codec of RFC 1035, and an opt-in read of `resolv.conf` (`dns/dns`). [Docs](https://www.agentica-lang.com/packages/dns/) |
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

## Tags

A tag is `PACKAGE-X.Y.Z`, where `PACKAGE` is the folder name (`prop-0.1.0`, `bond-channels-0.1.0`), so each package has its own versions. A release that needs a pre-release of Agentica is a pre-release too (`prop-0.3.0-alpha.1` needs Agentica 0.31.0-alpha.1). The `tag` of a dependency is that name, and `subdir` is the folder.

## Agentica versions

Each package needs its own Agentica version, written in `PACKAGE/AGENTICA_VERSION` (the version, then the sha256 of its `linux-x86_64` archive); the CHANGELOG of the package says when it changed. CI and the Makefile run each package on that version.

## Docs

The docs are at <https://www.agentica-lang.com/packages/>. Each package keeps its pages in its own `PACKAGE/docs/` folder (an `_index.md` at least), and `make site` builds them into one Hugo site in `site/public` (it needs the docs theme, `git submodule update --init`, plus Hugo, Dart Sass and Node; `make site-serve` previews it).

## Prebuilt native modules

`.github/workflows/native-prebuilt.yml` is a reusable workflow that builds the native module of a package on the five targets and uploads the files of its `prebuilt` table to a release of that package: [docs](https://www.agentica-lang.com/packages/native-prebuilt/).

Rules for contributors and agents: `AGENTS.md`.

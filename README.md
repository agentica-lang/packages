# packages

Small Agentica packages, one folder each. A folder is a package with its own `agentica.toml`; add one with its prefixed tag and its folder as `--subdir`, in a project with an `agentica.toml`:

```sh
agentica add prop agentica-lang/packages --tag prop-0.4.2 --subdir prop
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
| `native-gen` (`native-gen-0.5.0`) | The C header of an `extern module` block: typed prototypes, the argument checks, the codecs and the tables of the module, generated from the `.agc`, and `new` to start a module. [Docs](https://www.agentica-lang.com/packages/native-gen/) |
| `dock` (`dock-0.4.0`) | A TCP server: an accept loop, a task per client that runs your handler, and the clean-up when a client ends or crashes (`dock/dock.agc`). [Docs](https://www.agentica-lang.com/packages/dock/) |
| `http-client` (`http-client-0.5.1`) | An HTTP/1.1 client in the spirit of Req with opt-in multiplexed HTTP/2: a pool of keep-alive connections per origin on `pool`, `base_url`, client headers and params, JSON bodies, auth, gzip and deflate decoding, request and response steps, streamed bodies and server-sent events that can be cancelled, including incremental HTTP/2 streams with per-stream flow control, retries, redirects, and timeouts for the connect, the response head, the idle body, the whole request and the wait for a connection (`http-client/http_client`). [Docs](https://www.agentica-lang.com/packages/http-client/) |
| `pool` (`pool-0.1.3`) | A generic pool of resources in the style of NimblePool: long-lived resources lent to one caller at a time, with a line, a lease, a health tick and a close with a drain; a caller that ends never keeps its resource (`pool/pool`). [Docs](https://www.agentica-lang.com/packages/pool/) |
| `websocket-client` (`websocket-client-0.3.0`) | A WebSocket client (RFC 6455) over `std` TCP and TLS: `ws://` and `wss://`, text and binary messages, fragments, pings, the close handshake, a size limit and a read timeout (`websocket-client/websocket`). [Docs](https://www.agentica-lang.com/packages/websocket-client/) |
| `jobs` (`jobs-0.3.1`) | Produce and consume jobs with a swappable backend: leases, retries with a time, unique keys and dead jobs, an in-memory backend, a conformance suite that every backend must pass, telemetry events for its calls and the drain, and a manual clock and `Jobs.drain` for app tests (`jobs/jobs`, `jobs/conformance`). [Docs](https://www.agentica-lang.com/packages/jobs/) |
| `yaml` (`yaml-0.1.0`) | A YAML 1.2 parser: one document or a stream to `JSON.Value`, with the core schema only, string keys, limits on depth, aliases and size, and errors with a line and a column (`yaml/yaml`). [Docs](https://www.agentica-lang.com/packages/yaml/) |
| `dns` (`dns-0.1.0`) | A DNS client: queries over TCP, TLS and HTTPS to the nameservers you choose, tried in order, with CNAMEs followed, addresses with their TTLs, distinct errors, and a bounded codec of RFC 1035, and an opt-in read of `resolv.conf` (`dns/dns`). [Docs](https://www.agentica-lang.com/packages/dns/) |
| `telemetry` (`telemetry-0.1.0`) | Events for numbers, as `std/logger` is for text: `Telemetry.execute` says that something happened (a dotted name, integer and float measurements, string metadata) and costs one table read with no handler attached; handlers attached by id and name prefix each run in an actor with a bounded queue, so a slow or failing handler never hurts the emitter, with naming and unit conventions (`telemetry/telemetry`), a conformance check and a helper that captures events for tests (`telemetry/conformance`, `telemetry/testing`). [Docs](https://www.agentica-lang.com/packages/telemetry/) |
| `hpack` (`hpack-0.1.0`) | HPACK header blocks for HTTP/2, with a stateful decoder and a stateless encoder using the static table and raw literals. [Docs](https://www.agentica-lang.com/packages/hpack/) |
| `snappy` (`snappy-0.1.0`) | The Snappy raw block format in pure Agentica: a decoder that refuses every malformed block with a `snappy.malformed` error, and a greedy encoder. [Docs](https://www.agentica-lang.com/packages/snappy/) |
| `parquet` (`parquet-0.1.0`) | Parquet files in pure Agentica: the schema, the row count, and the columns or rows of a file, with plain, dictionary and RLE pages under Snappy or gzip. A malformed file is a `parquet.malformed` error. [Docs](https://www.agentica-lang.com/packages/parquet/) |
| `s3` (`s3-0.1.0`) | An S3 client for AWS S3, MinIO and rustfs in Agentica: Signature Version 4 requests, presigned URLs for direct uploads and downloads, objects from memory, a file or a stream, and multipart uploads, with the S3 error code as the error kind (`s3/s3`). [Docs](https://www.agentica-lang.com/packages/s3/) |
| `csv` (`csv-0.1.0`) | CSV (RFC 4180) in pure Agentica: rows as lists or maps, a chosen separator, a reader that takes the text in chunks, quoting when writing, and a `csv.malformed` error with its line. [Docs](https://www.agentica-lang.com/packages/csv/) |
| `image` (`image-0.2.0`) | Images on libvips, generated with native-gen: decode and encode (JPEG, PNG, WebP, TIFF and more), the pixels as one `Bytes` buffer, and resize (with a chosen kernel), crop, flip, rotate, colour conversion and cast. [Docs](https://www.agentica-lang.com/packages/image/) |
| `smtp` (`smtp-0.1.0`) | An SMTP client in Agentica: plain, STARTTLS and implicit TLS connections, AUTH PLAIN and LOGIN, and the message (RFC 5322 headers, encoded words, text and HTML bodies), with the reply code in the error (`smtp/smtp`). [Docs](https://www.agentica-lang.com/packages/smtp/) |
| `release` (unreleased) | Builds an app into a folder that runs on another machine, as `mix release` does: the `agentica` binary, the compiled program, a launcher and a manifest with the sha256 of every file; `tar` packs it and `inspect` checks it (`release/cli.agc`). [Docs](https://www.agentica-lang.com/packages/release/) |
| `cache` (planned) | Cache strategies (CLOCK, sampled LRU, TinyLFU) behind the `Cache` facade of `std/cache` |

## Tags

A tag is `PACKAGE-X.Y.Z`, where `PACKAGE` is the folder name (`prop-0.1.0`, `bond-channels-0.1.0`), so each package has its own versions. A release that needs a pre-release of Agentica is a pre-release too (`prop-0.3.0-alpha.1` needs Agentica 0.31.0-alpha.1). The `tag` of a dependency is that name, and `subdir` is the folder.

## Agentica versions

Each package needs its own Agentica version, written in `PACKAGE/AGENTICA_VERSION` (the version, then the sha256 of its `linux-x86_64` archive); the CHANGELOG of the package says when it changed. CI and the Makefile run each package on that version.

## Docs

The docs are at <https://www.agentica-lang.com/packages/>. Each package keeps its pages in its own `PACKAGE/docs/` folder (an `_index.md` at least), and `make site` builds them into one Hugo site in `site/public` (it needs the docs theme, `git submodule update --init`, plus Hugo, Dart Sass and Node; `make site-serve` previews it). The front matter of each `_index.md` holds the `category` (one of the list in `tools/catalog.py`), the `description` and the optional `keywords` of the package, which the sidebar and the table of the home page use; `make catalog` checks them.

## Prebuilt native modules

`.github/workflows/native-prebuilt.yml` is a reusable workflow that builds the native module of a package on the five targets and uploads the files of its `prebuilt` table to a release of that package: [docs](https://www.agentica-lang.com/packages/native-prebuilt/).

Rules for contributors and agents: `AGENTS.md`.

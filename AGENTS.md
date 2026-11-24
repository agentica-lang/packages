# packages

Small Agentica packages of `agentica-lang`, one folder each. `README.md` has the list and the tag scheme; planned work
is in GitHub issues of `agentica-lang/packages`.

## Map

```text
README.md            the table of packages and how to install one
Makefile             install, check, fmt-check, test and doc-examples, each run in every folder that has an
                     agentica.toml, on the Agentica version of that folder; site
tools/               doc_examples.agc: runs the `agentica` blocks of the docs (the rules are in its header);
                     fixtures/doc_examples: a page where it must fail; agentica-for.sh: the binary of a package's
                     Agentica version (the rules are in its header)
.github/workflows/   ci.yml: the changed packages grouped by Agentica version, one job per version that installs that
                     release and runs the five targets; pages.yml: the site (pinned Hugo and Dart Sass);
                     native-prebuilt.yml: the reusable workflow that builds a package's native module on the five
                     targets and uploads its prebuilt files (site/content/native-prebuilt.md), which
                     native-prebuilt-test.yml runs with dry-run on .github/native-prebuilt-example
.github/scripts/     changed-packages.sh: which packages a list of changed files marks (the rules are in its header)
site/                the Hugo site: hugo.toml, content/_index.md (the home), layouts/ (overrides: the home's list of
                     packages, and links written as files that fail when missing); the look, the layouts and the
                     highlighter come from themes/docs-theme (the submodule agentica-lang/docs-theme)
PACKAGE/             one package: AGENTICA_VERSION, agentica.toml, agentica.lock (when it has dependencies), src/,
                     specs/, test/, docs/
bond-channels/       Action Cable for Bond: channels.agc is the API (mount, hub, broadcast, stats); src/protocol.agc the frames
                     (pure), src/hub.agc the hub (an actor), src/connection.agc one connection, src/types.agc the records;
                     turbo_streams, stream_key and signed_stream_name are in channels.agc too: src/signing.agc the
                     Rails-format signed names (pure), src/turbo.agc the channel; specs/ has the frames, the cable
                     and the Turbo features (fixtures/ws_client/cable_client.agc is the peer: websocket-client in a
                     program with a manifest of its own, since a step cannot leave tasks running and the package must
                     not depend on it; fixtures/turbo_vectors.json is what Rails signed), bench/fanout.py measures
                     memory per socket and the hub's fan-out by hand, bench/hub_fanout.agc the hub alone (steps and
                     time per frame)
http-client/         an HTTP/1.1 client: http_client.agc is the API (new, request, get, post, ..., close); src/url.agc
                     the URL against base_url (pure), src/pools.agc the manager task that starts one `pool` per origin
                     (and closes those unused), src/link.agc the resource of a pool (a slot for one keep-alive
                     connection, run by a task of its own that opens and owns the connection and watches it while idle),
                     src/exchange.agc one request on a link (connect, send, read, the timeouts, when a connection is
                     reused), src/retry.agc when and after how long a request goes again, src/redirect.agc the next hop
                     of a redirect, src/dial.agc the opt-in dial path (the resolver, its cache and the connect to a
                     checked address), src/address.agc which IP addresses are public (pure), src/encoding.agc the
                     gzip and deflate decoding of a body, src/sse.agc the reading of server-sent events (pure); test/specs/
                     has the features (client, retries, redirects, dns, options, streams), whose program under test
                     is test/specs/driver.agc (a client, its requests and the peers, driven by JSON lines from
                     test/steps.agc); the peers are programs the
                     driver starts: fixtures/server.agc (the server of std/http, for the normal flows, or over HTTPS
                     with fixtures/tls/, a certificate for api.test and its CA) and fixtures/raw_peer.agc (a TCP server
                     that reads requests by hand and writes the answers of a script: slow heads, stalls, closes, and
                     which connection served each); test/ the unit tests (URL, addresses, retry policy, redirects, link,
                     a client's checks) and a reuse test (many requests on one connection, no task left after close)
image/               images on libvips (a native module made with native-gen): image.agc is the API and the extern
                     block (load, from_bytes, from_pixels, save, to_bytes, to_pixels, width, height, bands,
                     pixel_format); native/image.c the C side, native/image_native.h the header native-gen makes from
                     the block (a spec checks it is current); specs/ has the feature, whose fixtures are written by
                     specs/fixtures/peer.py (an independent PNG codec on Python's standard library, which also decodes
                     what the module writes)
jobs/                jobs to produce and consume, with the backend swappable: jobs.agc is the API (the `Backend`
                     record, enqueue, fetch, ack, nack, extend, counts, close, discard, json, decode, memory, drain,
                     manual_clock), conformance.agc the suite that every backend passes (run_all),
                     conformance/cases.agc its cases; src/types.agc the records, src/store.agc the jobs of the memory
                     backend and their rules (pure: each function takes the store and the time; it counts the live
                     leases of each group), src/memory.agc the actor that owns a store (the calls, the fetches that
                     wait, the close), src/parked.agc the fetches that wait (by queue and by deadline), src/settle.agc
                     what happens to a job after its handler (shared by `Jobs.drain` and the later pipeline),
                     src/inline.agc `Jobs.drain`, src/events.agc the telemetry events of the facade and the drain (one table read
                     with no handler attached); specs/ has the features (drain also checks what it logs; conformance:
                     the suite on the memory backend, on broken ones and on the real clock; events reads the
                     telemetry events that the driver captures and checks them with `Conformance.check`; stress also
                     matches the events with what its consumers did; memory, drain, stress: many
                     consumers and producers), whose program under test is specs/driver.agc (a memory backend and a
                     manual clock that a step program drives by JSON lines, specs/protocol.agc, specs/steps.agc),
                     specs/stress.agc the consumers and producers, and specs/model.agc an independent model of the
                     contract (plain lists, written from docs/contract.md, nothing of src/) that the memory feature
                     compares the backend with on random calls; test/jobs_test.agc, test/store_test.agc (the guarantees
                     of the store: leases, expiry, unique keys, batches, the last error), test/model_test.agc and
                     test/events_test.agc (the steps of the events with no handler) have the unit tests
native-gen/          the C header of an `extern module` block: cli.agc is the command, native_gen.agc the API
                     (`header`), src/header.agc the text of the header, src/codecs.agc the C values of the structs and
                     enums, src/collections.agc the Lists, Maps, Optionals and Results, src/types.agc the type
                     trees, src/names.agc the C names, src/scaffold.agc the files of `new`, src/rust.agc the
                     Rust file of `--lang rust` (all pure); native/agentica-native/ the crate agentica-native
                     (safe wrappers over agentica_native.h; `cargo test` there, CI job `rust`), in the package's
                     native/ folder so that `agentica install` copies it into deps/ and the lock hashes it;
                     rust/vm-check/ a module on it that run.sh builds and runs on the real VM (needs cargo),
                     rust/gen-check/ the fixtures stats, shapes, kinds and shapes2 on the Rust files native-gen makes,
                     run the same way; examples/rust_math/ the Rust module that the docs show, which
                     rust/build-check.sh builds with `cli.agc build` and runs, and compares with the docs' copies;
                     rust/new-check.sh builds and runs the module of `new --lang rust`;
                     specs/fixtures/ are packages written on their headers (the ones of stats and fresh are committed
                     as the goldens, a step makes the others: kinds, shapes, lists, options, resources), the files
                     that fail (errors/) and cxx.sh, a CC that builds a module as C++; bench/wide the codecs of a
                     struct of 26 fields; the features need cc and c++
dock/                a TCP server: dock.agc is the API (start, stop, wait, watch, stats, on_close, recv, send,
                     close); src/server.agc the supervisor task (listener, accept loop, monitors), src/connection.agc
                     the task of one client, src/outbox.agc its queue and writer, src/stats.agc the counters,
                     src/types.agc the records; test/dock_test.agc has the socket tests (real localhost sockets,
                     port 0)
dns/                 a DNS client: dns.agc is the API (resolver, query, addresses, lookup, lookuper, system_servers,
                     encode_query, decode);
                     src/client.agc the servers in order, the checks of the answer and the CNAMEs, src/transport.agc one
                     query over TCP, TLS or HTTPS, src/resolv.agc the nameservers of a resolv.conf, src/wire.agc the messages, src/name.agc the names and their compression (the
                     last two pure), src/types.agc the records; test/ has the unit tests; specs/codec.feature checks the
                     codec against specs/fixtures/dns_peer.py (an independent encoder and decoder in Python's standard
                     library, which also writes random and damaged messages); specs/transport.feature runs the resolver
                     against fixtures/dns_tcp_peer.agc (answers the hex bytes of a script, over TCP or, with TLS_CERT and
                     TLS_KEY, over TLS), specs/doh.feature against fixtures/doh_peer.agc (an HTTPS server with a script
                     by path; ca.pem signed server.pem for dns.test, key server.key, made for the specs only)
pool/                a generic pool of resources: pool.agc is the API (start, with, close, timeout?) and the caller's
                     side (the ticket, the body in the caller or in a task of its own); src/owner.agc the owner task
                     (the line, the workers' states, the health tick, the close), src/keeper.agc the task of one
                     resource (init, ping, checkin, terminate), src/types.agc the records and messages; specs/ has the features
                     (checkout, callers, lifecycle, outcomes), whose program under test is specs/driver.agc, a pool of
                     fake resources with counters that a step program drives by JSON lines (specs/protocol.agc,
                     specs/steps.agc); test/pool_test.agc has the unit test of `Pool.timeout?`; bench/checkout.agc
                     the checkouts per second
prop/                property-based testing: prop.agc is the API (check, eq, assume, the generators, the laws, of,
                     exhaustive); src/gen.agc the generators (with their small cases), src/tree.agc the shrink trees,
                     src/seed.agc the seed hashing (pure), src/check.agc the runner and the shrinking, src/laws.agc
                     the law helpers, src/schema.agc `Prop.of`, src/exhaustive.agc the bounded check; test/*_test.agc
                     are the unit tests (the API is plain function calls)
telemetry/           events for numbers: telemetry.agc is the API (start, stop, execute, enabled?, span, attach, detach,
                     handlers, dropped, flush); conformance.agc the check of an event against the conventions
                     (check); testing.agc the helper for tests (capture, events, stop, session); src/hub.agc the hub (the one actor that writes the routes, starts the actor of each
                     handler and detaches one that fails), src/handler.agc the actor of one handler (its bounded
                     queue), src/routes.agc the ATS tables that emitters read, src/names.agc the names and patterns
                     (pure), src/flush.agc the barrier, src/types.agc the records and messages; specs/ has the
                     features (emitting, handlers, failures, stress, spans, conventions, testing), whose program under test is
                     specs/driver.agc (the hub and its handlers, driven by JSON lines from specs/steps.agc), and
                     specs/stress.agc and specs/starts.agc the tasks that attach, detach, emit and start together;
                     test/cost_test.agc holds the steps of `execute` and of a span to a bound (System.Profile.steps,
                     no clock), test/names_test.agc the pure names and test/testing_test.agc a session in a unit test
websocket-client/    a WebSocket client (RFC 6455): websocket.agc is the API (connect, handshake, send_text, send_binary, send_ping,
                     send_pong, receive, close); src/frame.agc the frames (pure), src/handshake.agc the URL, the request
                     and the check of the answer (pure), src/connection.agc the socket, src/types.agc the records;
                     test/ has the unit tests of the two pure modules; specs/ has the features, whose peers are
                     fixtures/server.agc (the server of std/http, ws and wss; fixtures/cert.pem and key.pem are a
                     self-signed pair for localhost) and fixtures/raw_peer.agc (a TCP server that writes the hex
                     frames of a script and prints the frames it reads)
yaml/                a YAML 1.2 parser: yaml.agc is the API (parse, parse_all, Options); src/scanner.agc the scalars,
                     anchors and tags, src/parser.agc the documents and collections (a tree of src/types.agc nodes),
                     src/composer.agc the tree to JSON (aliases, keys), src/schema.agc the core schema, src/source.agc
                     the bytes and the errors (all pure); specs/ has the features; specs/fetch-suite.sh (run by
                     `make install`) fetches the official yaml-test-suite at a pinned commit and sha256 into
                     yaml/.cache/ (ignored), and specs/fixtures/suite.agc runs its cases in scope
                     (specs/fixtures/README.md says which)
```

## Commands

- Each package runs on its own Agentica version, in `PACKAGE/AGENTICA_VERSION`: one line, the version and the
  sha256 of its `linux-x86_64` archive (from `SHA256SUMS` of the release), which CI checks. The Makefile takes the
  binary from `~/.local/share/agentica/agentica-VERSION-PLATFORM/bin/` (`AGENTICA_HOME` moves it), or the `agentica`
  on PATH when it is that version; releases unpack there side by side. To move a package, edit that line, fix what
  `agentica check` reports, and add a `**Breaking:**` line to its CHANGELOG.
- `make install` fetches `deps/` from each lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`
  run in each package folder; to work on one package, `cd` into it and run `agentica check`, `agentica fmt --check`
  and `agentica test`.
- `make check PACKAGES="prop native-gen"` (any target) runs only those packages. A pull request runs the packages
  whose files changed (`.github/scripts/changed-packages.sh`), a push to main runs all of them; a change of a shared
  file (Makefile, `ci.yml`, a script) marks all. A package whose only change is in its `docs/` runs only its doc
  examples, and a pull request that changes only the site or top-level docs starts no CI (Pages builds the site). A
  new push to a pull request cancels its older run.
- `make site` builds the docs into `site/public` (needs the theme, `git submodule update --init`, Hugo, Dart Sass and
  Node; CI pins Hugo 0.167.0 and Dart Sass 1.105.1 in `pages.yml`);
  `make site-serve` previews them. A pull request builds the site, and a push to main deploys it to GitHub Pages.
- To move a dependency: `agentica add NAME URL --tag TAG` in the package folder, and commit the lock.

## Rules

- A package stands alone: it imports only the names of its own `agentica.toml` and its own files, and nothing from a
  sibling folder. Two packages that need one piece of code get it from a dependency, not by copy.
- Each package needs at least one source file in `src/` and a spec in `specs/` (or a unit test in `test/`): `agentica
  check` and `agentica test` fail on a folder with no `.agc` file or nothing to run, and the Makefile stops there.
- A dependency is pinned by tag (or by commit) and keeps the local name of the apps that use it, at the same tag:
  two sources for one name in a tree is `PKG-SOURCE-CONFLICT`. A bump of Bond is a package release first, then the
  app.
- `agentica.toml` has `blank_line_after_end = true`: every bare `end` is followed by an empty line.
- BDD first: a behavior is a Gherkin scenario in `specs/` or `test/specs/`, with steps in `specs/steps.agc` or `test/steps.agc` respectively. A pure helper may have a
  unit test in `test/` (`*_test.agc`). Tests are hermetic: 127.0.0.1, port 0, no external services, and a step that makes
  something on disk removes it with `BDD.after`.
- Tests, models and peers are written in Agentica. A peer in another language (Python or Node, standard library
  only) is for a protocol or format that must agree with an independent implementation, such as a wire codec
  (dns's `dns_peer.py`); a model of a package's own logic is Agentica.
- Each package keeps its docs in its own `PACKAGE/docs/`, as Markdown with a front matter (`title`, `description`,
  `weight` to order a page): `_index.md` is the package page (what it is, the `agentica add` command with `--subdir` and
  the prefixed tag and the `agentica.toml` line it writes, a short example, the API), and each other `.md` is a page of
  it. `make site` mounts each `docs/` as `/PACKAGE/`, so a new package adds its docs with that folder alone, and no file
  of `site/` changes. Link to a page as `[text](page.md)`; a broken link fails the build. Examples in the docs must run
  (an `agentica` code block is colored with the Agentica grammar): `make doc-examples` runs each block with `def main`
  and compares its stdout with an `output` block right after it (a `text` block is never compared), checks the others,
  and skips a block marked `{mode="fragment"}` (`{mode="check"}` only checks one, such as a server). Many existing
  blocks are still fragments; a new example is a whole file with its `output`. The rules are in the header of
  `tools/doc_examples.agc`, and `make doc-examples-test` checks the tool on its fixture. Site prose: one line per
  paragraph or list item, simple words.
- `make test` runs the files and scenarios of a package `JOBS` at a time, so a scenario never writes in a folder
  that another one uses: it makes a fresh one (native-gen copies a fixture package before it builds it).
- Each package has its own CHANGELOG.md; a user-visible change adds a line under its `## [Unreleased]`; a release renames
  it to `## [X.Y.Z] - DATE` and tags `PACKAGE-X.Y.Z`.
- Release: a tag `PACKAGE-X.Y.Z` on main, made by the owner, or by the coordinator after the owner confirms that
  release. A PR never pushes a tag.
- Code style is the one of `agentica-code-guidelines`; a comment says why, not what.

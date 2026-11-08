# packages

Small Agentica packages of `agentica-lang`, one folder each. `README.md` has the list and the tag scheme; planned work
is in GitHub issues of `agentica-lang/packages`.

## Map

```text
README.md            the table of packages and how to install one
Makefile             install, check, fmt-check and test, each run in every folder that has an agentica.toml
.github/workflows/   ci.yml: the pinned Agentica release, then the four targets
PACKAGE/             one package: agentica.toml, agentica.lock (when it has dependencies), src/, specs/, test/
bond-channels/       Action Cable for Bond: channels.agc is the API (mount, hub, broadcast, stats); src/protocol.agc the frames
                     (pure), src/hub.agc the hub task, src/connection.agc one connection, src/types.agc the records;
                     turbo_streams, stream_key and signed_stream_name are in channels.agc too: src/signing.agc the
                     Rails-format signed names (pure), src/turbo.agc the channel; specs/ has the frames, the cable
                     and the Turbo features (fixtures/cable_peer.py is a raw-socket peer, it needs python3;
                     fixtures/turbo_vectors.json is what Rails signed), bench/fanout.py measures memory per socket
                     and the hub's fan-out by hand, bench/hub_fanout.agc the hub alone (steps and time per frame)
prop/                property-based testing: prop.agc is the API (check, eq, assume, the generators, the laws, of,
                     exhaustive); src/gen.agc the generators (with their small cases), src/tree.agc the shrink trees,
                     src/seed.agc the seed hashing (pure), src/check.agc the runner and the shrinking, src/laws.agc
                     the law helpers, src/schema.agc `Prop.of`, src/exhaustive.agc the bounded check; test/*_test.agc
                     are the unit tests (the API is plain function calls)
```

## Commands

- Agentica 0.25.0 on PATH (CI pins it with its sha256 in `ci.yml`; `AGENTICA=/path/agentica make ...` works too).
- `make install` fetches `deps/` from each lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`
  run in each package folder; to work on one package, `cd` into it and run `agentica check`, `agentica fmt --check`
  and `agentica test`.
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
- BDD first: a behavior is a Gherkin scenario in `specs/`, with steps in `specs/steps.agc`. A pure helper may have a
  unit test in `test/` (`*_test.agc`). Tests are hermetic: 127.0.0.1, port 0, no external services, and a step that makes
  something on disk removes it with `BDD.after`.
- Each package has its own CHANGELOG.md; a user-visible change adds a line under its `## [Unreleased]`; a release renames
  it to `## [X.Y.Z] - DATE` and tags `PACKAGE-X.Y.Z`.
- Release: a tag `PACKAGE-X.Y.Z` on main, made by the owner. A PR never pushes a tag.
- Code style is the one of `agentica-code-guidelines`; a comment says why, not what.

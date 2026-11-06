# packages

Small Agentica packages of `agentica-lang`, one folder each. `README.md` has the list and the tag scheme; planned work
is in GitHub issues of `agentica-lang/packages`.

## Map

```text
README.md            the table of packages and how to install one
Makefile             install, check, fmt-check and test, each run in every folder that has an agentica.toml
.github/workflows/   ci.yml: the pinned Agentica release, then the four targets
PACKAGE/             one package: agentica.toml, agentica.lock (when it has dependencies), src/, specs/, test/
bond-channels/       Action Cable for Bond; src/protocol.agc is the frame encode and decode (pure)
```

## Commands

- Agentica 0.24.4 on PATH (CI pins it with its sha256 in `ci.yml`; `AGENTICA=/path/agentica make ...` works too).
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
- Release: a tag `PACKAGE-X.Y.Z` on main, made by the owner. A PR never pushes a tag.
- Code style is the one of `agentica-code-guidelines`; a comment says why, not what.

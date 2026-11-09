# packages

Small Agentica packages of `agentica-lang`, one folder each. `README.md` has the list and the tag scheme; planned work
is in GitHub issues of `agentica-lang/packages`.

## Map

```text
README.md            the table of packages and how to install one
Makefile             install, check, fmt-check, test and doc-examples, each run in every folder that has an
                     agentica.toml; site
tools/               doc_examples.agc: runs the `agentica` blocks of the docs (the rules are in its header);
                     fixtures/doc_examples: a page where it must fail
.github/workflows/   ci.yml: the changed packages, the pinned Agentica release, then the five targets; pages.yml: the
                     site (pinned Hugo and Dart Sass)
.github/scripts/     changed-packages.sh: which packages a list of changed files marks (the rules are in its header)
site/                the Hugo site: hugo.toml, content/_index.md (the home), layouts/ (overrides: the home's list of
                     packages, and links written as files that fail when missing); the look, the layouts and the
                     highlighter come from themes/docs-theme (the submodule agentica-lang/docs-theme)
PACKAGE/             one package: agentica.toml, agentica.lock (when it has dependencies), src/, specs/, test/, docs/
bond-channels/       Action Cable for Bond: channels.agc is the API (mount, hub, broadcast, stats); src/protocol.agc the frames
                     (pure), src/hub.agc the hub task, src/connection.agc one connection, src/types.agc the records;
                     turbo_streams, stream_key and signed_stream_name are in channels.agc too: src/signing.agc the
                     Rails-format signed names (pure), src/turbo.agc the channel; specs/ has the frames, the cable
                     and the Turbo features (fixtures/cable_peer.py is a raw-socket peer, it needs python3;
                     fixtures/turbo_vectors.json is what Rails signed), bench/fanout.py measures memory per socket
                     and the hub's fan-out by hand, bench/hub_fanout.agc the hub alone (steps and time per frame)
native-gen/          the C header of an `extern module` block: cli.agc is the command, native_gen.agc the API
                     (`header`), src/header.agc the text of the header, src/codecs.agc the C values of the structs and
                     enums, src/collections.agc the Lists, Maps, Optionals and Results, src/types.agc the type
                     trees, src/names.agc the C names, src/scaffold.agc the files of `new`, src/rust.agc the
                     Rust file of `--lang rust` (all pure); native/agentica-native/ the crate agentica-native
                     (safe wrappers over agentica_native.h; `cargo test` there, CI job `rust`), in the package's
                     native/ folder so that `agentica install` copies it into deps/ and the lock hashes it;
                     rust/vm-check/ a module on it that run.sh builds and runs on the real VM (needs cargo),
                     rust/gen-check/ the fixtures stats, shapes, kinds and shapes2 on the Rust files native-gen makes,
                     run the same way;
                     specs/fixtures/ are packages written on their headers (the one of stats is committed as the
                     golden, a step makes the others: kinds, shapes, lists, options, resources), the files that fail
                     (errors/) and cxx.sh, a CC that builds a module as C++; bench/wide the codecs of a struct of 26
                     fields; the features need cc and c++
prop/                property-based testing: prop.agc is the API (check, eq, assume, the generators, the laws, of,
                     exhaustive); src/gen.agc the generators (with their small cases), src/tree.agc the shrink trees,
                     src/seed.agc the seed hashing (pure), src/check.agc the runner and the shrinking, src/laws.agc
                     the law helpers, src/schema.agc `Prop.of`, src/exhaustive.agc the bounded check; test/*_test.agc
                     are the unit tests (the API is plain function calls)
```

## Commands

- Agentica 0.27.0 on PATH (CI pins it with its sha256 in `ci.yml`; `AGENTICA=/path/agentica make ...` works too).
- `make install` fetches `deps/` from each lock (git ignores `deps/`). `make check`, `make fmt-check`, `make test`
  run in each package folder; to work on one package, `cd` into it and run `agentica check`, `agentica fmt --check`
  and `agentica test`.
- `make check PACKAGES="prop native-gen"` (any target) runs only those packages. A pull request runs the packages
  whose files changed (`.github/scripts/changed-packages.sh`), a push to main runs all of them; a change of a shared
  file (Makefile, `ci.yml`, a script) marks all.
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
- BDD first: a behavior is a Gherkin scenario in `specs/`, with steps in `specs/steps.agc`. A pure helper may have a
  unit test in `test/` (`*_test.agc`). Tests are hermetic: 127.0.0.1, port 0, no external services, and a step that makes
  something on disk removes it with `BDD.after`.
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
- Each package has its own CHANGELOG.md; a user-visible change adds a line under its `## [Unreleased]`; a release renames
  it to `## [X.Y.Z] - DATE` and tags `PACKAGE-X.Y.Z`.
- Release: a tag `PACKAGE-X.Y.Z` on main, made by the owner. A PR never pushes a tag.
- Code style is the one of `agentica-code-guidelines`; a comment says why, not what.

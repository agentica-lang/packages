# Changelog

## [Unreleased]

- **Breaking:** a release keeps the agentica binary in `runtime/`, not `erts/`; `inspect` of this version refuses a release built by 0.1.0.

## [0.1.0] - 2026-11-25

- Add `release`: builds an app into a folder that runs on another machine (the `agentica` binary, the compiled program, a launcher and a manifest with sha256 of every file), packs it as a `.tar.gz` and checks it again with `inspect`. Needs Agentica 0.39.0.

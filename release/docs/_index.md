---
title: release
description: Builds an app into a folder that runs on another machine, as mix release does. It holds the agentica binary, the compiled program, a launcher and a manifest.
category: Tooling
keywords: [release, deploy, tar, launcher]
---

`release` builds an app once and ships it. The result is a folder (or a `.tar.gz` of it) with the `agentica` binary, the program compiled to bytecode, a launcher script and a manifest. The machine that runs it needs nothing else: no Agentica install, no sources, no `deps/`, no network.

It works because a compiled program already holds the `std/` modules and the pure packages it uses. A release is small next to `mix release`, which copies the whole Erlang runtime: here it is the binary (about 30 MB) and the bytecode.

It is a tool package, run with `agentica`. It does no change to the `agentica` command.

## Install

Needs Agentica 0.39.0. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add release https://github.com/agentica-lang/packages --tag release-0.1.0 --subdir release
```

The dependency entry is:

```toml
release = { git = "https://github.com/agentica-lang/packages", tag = "release-0.1.0", subdir = "release" }
```

## Build a release

In the project folder:

```sh
agentica deps/release/cli.agc build
agentica deps/release/cli.agc tar _release/app-1.0.0
agentica deps/release/cli.agc inspect _release/app-1.0.0-linux-x86_64.tar.gz
```

`build` compiles the entry file with the `agentica` that PATH finds (or `--agentica FILE`) and ships that same binary, so the bytecode and the binary always have the same version. It writes `_release/NAME-VERSION/`:

```text
bin/NAME                  the launcher
erts/agentica             the binary
lib/NAME.agcb             the compiled program
releases/manifest.json    name, version, agentica version, system, architecture, sha256 of each file
```

plus the files and folders of `include`, at the same path as in the project. `bin/NAME` finds its folder from where it is, so the release can be moved or unpacked anywhere, and it sets `RELEASE_ROOT` to that folder for the program to find its `include` files. Its arguments are the program's arguments, and its exit code is the program's. It uses the shell and nothing else of the target, and it finds the folder from the path it was run by, so run it by that path, not through a link to it.

A release runs on the same system and architecture that built it, with the same glibc rules as the `agentica` binary (glibc 2.28 or later on Linux; not musl).

## Configure

The name comes from `agentica.toml`. The rest is in `[tool.release]`, a table that Agentica reads nothing in:

```toml
name = "app"
agentica = "0.39.0"

[tool.release]
version = "1.0.0"
entry = "main.agc"
include = ["assets", "migrations"]
agentica = "0.39.0"
```

- `version` is required (or `--version`). The folder is `NAME-VERSION`. Name and version are letters, digits, `.`, `_` and `-`.
- `entry` is the program to compile, `main.agc` by default.
- `include` lists files or folders of the project to copy into the release.
- `agentica` is a version the binary must have; a release with another binary is refused.
- `name` here overrides the name of the manifest.

## Native libraries

A native library that the manifest stores by its path on the build machine does not travel, so a project with `[native.NAME]` entries of `file` or `build` is refused (`release.invalid`) until Agentica can move them ([agentica-lang/agentica#1753](https://github.com/agentica-lang/agentica/issues/1753)). A library found by name (`system = "libNAME.so"`) is allowed: `build` lists it, and the target must have it. The natives of dependencies are not checked yet.

## Errors

- `release.invalid`: a bad name, version, entry or include, a native library stored by path, a binary that is not the version asked for, or a folder that exists already.
- `release.failed`: `agentica compile`, `cp`, `tar` or another program exited with an error; the message has its output.
- `release.corrupt`: `inspect` found a file that is missing, not in the manifest, or with another sha256.

## API

### `Release.build(options: Release.Options) -> Result[Release.Built]`

Makes the release folder of the project in `options.project`. `Options` has `project` (default `.`), `out` (`_release`), `agentica`, `version` and `entry` (empty: the default). It gives `Built(path, manifest, system_libraries)`.

```agentica
import Release from "pkg/release/release"

def main() -> Void
  Dir.mkdir("demo-app").unwrap!
  File.write_text("demo-app/agentica.toml", "name = \"demo\"\n[tool.release]\nversion = \"0.1.0\"\n").unwrap!
  File.write_text("demo-app/main.agc", "def main() -> Void\n  puts(System.args().join(\" \"))\nend\n").unwrap!
  built = Release.build(Release.Options(project: "demo-app", out: "demo-out")).unwrap!
  puts(built.manifest.files.map { |entry| entry.path })
  child = Process.spawn_captured("#{built.path}/bin/demo", ["hello", "world"]).unwrap!
  puts(Process.output(child, 30000).unwrap!.stdout.strip)
  Process.close(child)
  Path.remove("demo-app").unwrap!
  Path.remove("demo-out").unwrap!
end
```

```output
["bin/demo", "erts/agentica", "lib/demo.agcb"]
hello world
```

### `Release.tar(folder: String) -> Result[String]`

Checks the release folder, then writes `NAME-VERSION-OS-ARCH.tar.gz` beside it with the system `tar`, and gives its path.

### `Release.inspect(path: String) -> Result[Release.Manifest]`

Reads `releases/manifest.json` of a release folder or `.tar.gz` and checks it: every listed file is there with its sha256, and no other file is. It gives the manifest (`name`, `version`, `agentica`, `os`, `arch`, `files`), or a `release.corrupt` error that names the first file that does not match.

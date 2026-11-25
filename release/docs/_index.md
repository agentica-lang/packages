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

`build` compiles the entry file with the `agentica` that PATH finds (or `--agentica FILE`, and `--out DIR` and `--entry FILE` choose the folder and the program) and ships that same binary, so the bytecode and the binary always have the same version. It checks the project first (the entry, each `include`, the native libraries), writes `_release/NAME-VERSION.partial/` and renames it to `_release/NAME-VERSION/` when it is whole, so a failed build leaves no release folder. It writes:

```text
bin/NAME                  the launcher
erts/agentica             the binary
lib/NAME.agcb             the compiled program
releases/manifest.json    name, version, agentica version, system, architecture, sha256 of each file
```

plus the files and folders of `include`, at the same path as in the project. `bin/NAME` finds its folder from where it is, so the release can be moved or unpacked anywhere, and it sets `RELEASE_ROOT` to that folder for the program to find its `include` files. Its arguments are the program's arguments, and its exit code is the program's. It uses the shell and nothing else of the target, and it finds the folder from the path it was run by, so run it by that path, not through a link to it.

A release runs on the same system and architecture that built it, with the same glibc rules as the `agentica` binary (glibc 2.28 or later on Linux; not musl). Ship an official release binary (or one you built with the libraries vendored, `make AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored AGENTICA_ZLIB=vendored`) with `--agentica FILE`: a local build linked to the system OpenSSL, libgc and zlib needs them on the target. Windows is refused for now, since the launcher is an sh script.

## Configure

The name comes from `agentica.toml`. The rest is in `[tool.release]`, a table that Agentica reads nothing in:

```toml
name = "app"
agentica = "0.39.0"

[tool.release]
version = "1.0.0"
entry = "main.agc"
include = ["assets", "migrations"]
```

- `version` is required. The folder is `NAME-VERSION`. Name and version are letters, digits, `.`, `_` and `-`.
- `entry` is the program to compile, `main.agc` by default.
- `include` lists files or folders of the project to copy into the release. A path is relative, with no `.` or `..`, none is inside another, and the first folder is not `bin`, `erts`, `lib` or `releases`. A link is refused, as is a path that leaves the project through one.
- `name` here overrides the name of the manifest.
- `agentica` (top level, the oldest Agentica the project needs) is checked by `agentica compile`, as it is for any program.

## Native libraries

A native library that the manifest stores by its path on the build machine does not travel, so a project with `[native.NAME]` entries of `file` or `build` is refused (`release.invalid`) until Agentica can move them ([agentica-lang/agentica#1753](https://github.com/agentica-lang/agentica/issues/1753)). Only one shape is allowed: a `linux`, `macos` or `windows` table with `system = "libNAME.so"`, a library found by name. `build` lists it, and the target must have it. Any other shape is refused too, so a form that a later Agentica adds is not shipped by accident. The same check runs on every `deps/*/agentica.toml`, and a package of `agentica.lock` that is not in `deps/` is an error (run `agentica install`).

## Archives

`tar` writes `NAME-VERSION-OS-ARCH.tar.gz` beside the folder with the system `tar` (`std/archive` reads archives and does not write them) and does not replace one that exists. The archive is not reproducible: it holds the times and the modes of the files, and the umask of the machine that unpacks it applies. `inspect` of an archive lists it first and refuses a name that leaves the folder, a link or a special file, then unpacks it in a temporary folder without the owner or the permissions of the archive, and removes it.

`inspect` finds a release that is damaged, not one that is changed on purpose: whoever changes a file can change the manifest too. To know that an archive is the one you built, publish its sha256 apart from it.

## Errors

- `release.invalid`: a bad name, version, entry or include (a link, or a path that leaves the project), a native library that cannot travel, Windows, or a folder or archive that exists already.
- `release.failed`: `agentica compile` (a project that needs a newer Agentica than the binary, for one), `cp`, `tar` or another program exited with an error; the message has its output.
- `release.corrupt`: `inspect` found a file that is missing, not in the manifest, not executable (the launcher and the binary), with another sha256, or a manifest or archive that is not a release.

## API

### `Release.build(options: Release.Options) -> Result[Release.Built]`

Makes the release folder of the project in `options.project`. `Options` has `project` (default `.`), `out` (`_release`), `agentica` and `entry` (empty: the default). It gives `Built(path, manifest, system_libraries)`.

```agentica
import Release from "pkg/release/release"

def main() -> Void
  Path.remove("demo-app").unwrap!
  Path.remove("demo-out").unwrap!
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

Checks the release folder, then writes `NAME-VERSION-OS-ARCH.tar.gz` beside it with the system `tar`, and gives its path. An archive that exists is an error.

### `Release.inspect(path: String) -> Result[Release.Manifest]`

Reads `releases/manifest.json` of a release folder or `.tar.gz` and checks it: every listed file is there with its sha256, and no other file is, and the launcher and the binary are executable. It gives the manifest (`name`, `version`, `agentica`, `os`, `arch`, `files`), or a `release.corrupt` error that names the first file that does not match. It detects damage, not tampering (see Archives).

## The shape of a release folder and its manifest. It does no I/O.

MANIFEST = "releases/manifest.json"

## One file of the release: its path from the root of the folder and the sha256 of its bytes, as hex.
struct Entry
  path: String
  sha256: String
end

## `releases/manifest.json`: what the release is, where it runs and the hash of every file but this one.
struct Manifest
  name: String
  version: String
  agentica: String
  os: String
  arch: String
  files: List[Entry]
end

## `path` below `root`.
def at(root: String, path: String) -> String = "#{root}/#{path}"

## The folder of a release: `NAME-VERSION`.
def folder(name: String, version: String) -> String = "#{name}-#{version}"

## The archive of a release: `NAME-VERSION-OS-ARCH.tar.gz`.
def archive(manifest: Manifest) -> String
  "#{folder(manifest.name, manifest.version)}-#{manifest.os}-#{manifest.arch}.tar.gz"
end

def binary_path() -> String = "erts/agentica"

def program_path(name: String) -> String = "lib/#{name}.agcb"

def launcher_path(name: String) -> String = "bin/#{name}"

## The script of `bin/NAME`: it finds the root of the release from its own place (with the shell alone, so no program
## of the target is needed), tells the program where it is in `RELEASE_ROOT`, and runs the program with the binary of
## the release and the arguments it was given.
def launcher(name: String) -> String
  [
    "#!/bin/sh",
    "case $0 in */*) HERE=${0%/*} ;; *) HERE=. ;; esac",
    "ROOT=$(cd \"$HERE/..\" && pwd -P) || exit 1",
    "RELEASE_ROOT=$ROOT",
    "export RELEASE_ROOT",
    "exec \"$ROOT/#{binary_path()}\" run -- \"$ROOT/#{program_path(name)}\" \"$@\"",
    "",
  ].join("\n")
end

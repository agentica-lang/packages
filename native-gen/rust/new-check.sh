#!/bin/sh
# Runs `cli.agc new --lang rust demo` in an empty folder, with native-gen's crate in its deps/ where `agentica install`
# puts it, then `build demo.agc` and the program, with no edit: the module builds and loads, and the call of its one
# function fails with RUNTIME-NATIVE-ERROR "add: not written yet", as the C scaffold's does. The crate passes fmt
# (with rustfmt's defaults) and clippy -D warnings. Needs cargo and agentica on PATH.
set -eu
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
cli=$root/native-gen/cli.agc
pkg=$(mktemp -d)
trap 'rm -rf "$pkg"' EXIT
cd "$pkg"
agentica "$cli" new --lang rust demo
mkdir -p deps/native-gen
ln -s "$root/native-gen/native" deps/native-gen/native
agentica "$cli" build demo.agc
if AGENTICA_GC_HEAP=0 agentica demo.agc > out.txt 2> err.txt; then
  echo "new-check: demo.agc ran, but its stub should fail the call" >&2
  exit 1
fi
grep -q 'RUNTIME-NATIVE-ERROR' err.txt
grep -q 'add: not written yet' err.txt
cargo fmt --check --manifest-path rust/Cargo.toml
cargo clippy --quiet --manifest-path rust/Cargo.toml -- -D warnings
echo "new-check: ok"

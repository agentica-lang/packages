#!/bin/sh
# Runs `cli.agc new --lang rust NAME` in an empty folder, for demo, raise and agentica, with native-gen's crate in its
# deps/ where `agentica install` puts it, then `build NAME.agc` and the program, with no edit: the module builds and
# loads, and the call of its one function fails with RUNTIME-NATIVE-ERROR "add: not written yet", as the C scaffold's
# does. The crate passes fmt (with rustfmt's defaults) and clippy -D warnings. Needs cargo and agentica on PATH.
set -eu
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
cli=$root/native-gen/cli.agc
pkg=$(mktemp -d)
trap 'rm -rf "$pkg"' EXIT
# demo; raise, whose name is also a type of the crate; and agentica, whose module agentica_native has the name of the
# crate it depends on.
for name in demo raise agentica; do
  dir=$pkg/$name
  mkdir "$dir"
  cd "$dir"
  agentica "$cli" new --lang rust "$name"
  mkdir -p deps/native-gen
  ln -s "$root/native-gen/native" deps/native-gen/native
  agentica "$cli" build "$name.agc"
  if AGENTICA_GC_HEAP=0 agentica "$name.agc" > out.txt 2> err.txt; then
    echo "new-check: $name.agc ran, but its stub should fail the call" >&2
    exit 1
  fi
  grep -q 'RUNTIME-NATIVE-ERROR' err.txt
  grep -q 'add: not written yet' err.txt
  cargo fmt --check --manifest-path rust/Cargo.toml
  cargo clippy --quiet --manifest-path rust/Cargo.toml -- -D warnings
done
echo "new-check: ok"

#!/bin/sh
# Makes the Rust file of the fixtures stats, shapes, kinds and shapes2 with native-gen (then --check passes on it),
# builds a module on each (one cargo feature per module, as each exports agentica_native_init), lints it, and runs the
# fixture's program on it against the real VM: its output must be the one in expected/. Needs cargo and agentica on
# PATH.
set -eu
cd "$(dirname "$0")"
fixtures=../../specs/fixtures
for name in stats shapes kinds shapes2; do
  agentica ../../cli.agc "$fixtures/$name/$name.agc" --lang rust --output "src/${name}_native.rs"
  agentica ../../cli.agc "$fixtures/$name/$name.agc" --lang rust --output "src/${name}_native.rs" --check
  cargo clippy --quiet --features "$name" -- -D warnings
  cargo build --release --quiet --features "$name"
  run="target/run/$name"
  mkdir -p "$run/native"
  cp "target/release/libgen_check.so" "$run/native/lib$name.so"
  cp "$fixtures/$name/$name.agc" "$run/"
  printf 'name = "%s"\n\n[native.%s]\nlinux = { file = "native/lib%s.so" }\n' "$name" "$name" "$name" > "$run/agentica.toml"
  AGENTICA_GC_HEAP=0 agentica "$run/$name.agc" > "$run/out.txt"
  diff -u "expected/$name.txt" "$run/out.txt"
done
echo "gen-check: ok"

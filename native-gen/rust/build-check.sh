#!/bin/sh
# Runs `cli.agc build` on a copy of the fixture rust_math, with native-gen's crate in its deps/ where `agentica install`
# puts it, and checks the end states: the first build adds the [native.math] entry of the system and the program's
# output is the golden; a second build has nothing to do; a changed library is replaced; an entry that is there
# already keeps its own file, which gets the library. Lints and checks the format of the crate too. Needs cargo and
# agentica on PATH; Linux only.
set -eu
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
fixture=$root/native-gen/specs/fixtures/rust_math
pkg=$(mktemp -d)
trap 'rm -rf "$pkg"' EXIT
cli=$root/native-gen/cli.agc
cp -R "$fixture/." "$pkg"
rm -rf "$pkg/rust/target" "$pkg/native"
cp rustfmt.toml "$pkg/rust/"
mkdir -p "$pkg/deps/native-gen"
ln -s "$root/native-gen/native" "$pkg/deps/native-gen/native"

# The committed Rust file is the one the .agc gives.
agentica "$cli" build "$fixture/math.agc" --check

# The first build: the library goes to native/libmath.so, and the entry is added at the end of agentica.toml.
agentica "$cli" build "$pkg/math.agc" | tee "$pkg/first.txt"
grep -qx "copied .* to $pkg/native/libmath.so" "$pkg/first.txt"
entry='\n[native.math]\nlinux = { file = "native/libmath.so" }\n'
{ cat "$fixture/agentica.toml"; printf "$entry"; } > "$pkg/manifest.txt"
diff -u "$pkg/manifest.txt" "$pkg/agentica.toml"
AGENTICA_GC_HEAP=0 agentica "$pkg/math.agc" > "$pkg/out.txt"
diff -u "$fixture/expected.txt" "$pkg/out.txt"

# A second build has nothing to do: every line says so, and agentica.toml is the same.
agentica "$cli" build "$pkg/math.agc" | tee "$pkg/second.txt"
printf '%s\n' "$pkg/rust/src/math_native.rs is current" "$pkg/native/libmath.so is current" \
  "$pkg/agentica.toml has native.math.linux" | diff -u - "$pkg/second.txt"
diff -u "$pkg/manifest.txt" "$pkg/agentica.toml"

# A library that differs is replaced in place (File.replace), and the program runs on the new one.
printf 'old' > "$pkg/native/libmath.so"
agentica "$cli" build "$pkg/math.agc" | grep -qx "copied .* to $pkg/native/libmath.so"
AGENTICA_GC_HEAP=0 agentica "$pkg/math.agc" > "$pkg/out.txt"
diff -u "$fixture/expected.txt" "$pkg/out.txt"

# An entry that is there already keeps its file, which gets the library; agentica.toml does not change.
printf 'name = "math"\n\n[native.math]\nlinux = { file = "native/linux/math.so" } # kept\n' > "$pkg/agentica.toml"
cp "$pkg/agentica.toml" "$pkg/manifest.txt"
agentica "$cli" build "$pkg/math.agc"
diff -u "$pkg/manifest.txt" "$pkg/agentica.toml"
AGENTICA_GC_HEAP=0 agentica "$pkg/math.agc" > "$pkg/out.txt"
diff -u "$fixture/expected.txt" "$pkg/out.txt"

cargo fmt --check --manifest-path "$pkg/rust/Cargo.toml"
cargo clippy --quiet --manifest-path "$pkg/rust/Cargo.toml" -- -D warnings
echo "build-check: ok"

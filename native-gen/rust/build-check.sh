#!/bin/sh
# Runs `cli.agc build` on a copy of examples/rust_math, with native-gen's crate in its deps/ where `agentica install`
# puts it. Checks that docs/_index.md shows its files and the output of build and of the program, and the end states:
# the first build adds the [native.math] entry of the system and the program's output is the golden; a second build
# has nothing to do; a changed library is replaced; an entry that is there already keeps its own file, which gets the
# library. Lints and checks the format of the crate too. Needs cargo and agentica on PATH; Linux only.
set -eu
cd "$(dirname "$0")"
root=$(cd ../.. && pwd)
fixture=$root/native-gen/examples/rust_math
pkg=$(mktemp -d)
trap 'rm -rf "$pkg"' EXIT
cli=$root/native-gen/cli.agc
docs=$root/native-gen/docs/_index.md

# The fenced block of the docs page whose caption is the line $1, without its fences. Fails unless the caption occurs
# once, the next line that is not blank opens the block, and the block is closed and holds a line.
doc_block() {
  awk -v caption="$1" '
    $0 == caption { count++; if (count == 1) state = 1; next }
    state == 1 && $0 == "" { next }
    state == 1 && /^```/ { state = 2; next }
    state == 1 { state = 9; next }
    state == 2 && /^```/ { state = 3; next }
    state == 2 { print; lines++ }
    END { if (count != 1 || state != 3 || lines == 0) exit 1 }
  ' "$docs"
}

# Fails when the block of the docs page whose caption is $1 is not the file $2.
same() {
  doc_block "$1" > "$pkg/block.txt" ||
    { echo "build-check: $docs needs the caption $1 once, then a block with text" >&2; exit 1; }
  diff -u "$2" "$pkg/block.txt" || { echo "build-check: the block after $1 in $docs is not $2" >&2; exit 1; }
}

cp -R "$fixture/." "$pkg"
rm -rf "$pkg/rust/target" "$pkg/native"
cp rustfmt.toml "$pkg/rust/"
mkdir -p "$pkg/deps/native-gen"
ln -s "$root/native-gen/native" "$pkg/deps/native-gen/native"

# The committed Rust file is the one the .agc gives.
agentica "$cli" build "$fixture/math.agc" --check

# The files that docs/_index.md shows are the example's own.
same "\`agentica.toml\`, before the build:" "$fixture/agentica.toml"
same "\`math.agc\`:" "$fixture/math.agc"
same "\`rust/Cargo.toml\`:" "$fixture/rust/Cargo.toml"
same "\`rust/src/lib.rs\`:" "$fixture/rust/src/lib.rs"
same "The output of \`agentica math.agc\`:" "$fixture/expected.txt"

# The first build, run from the package root as the docs show it, without the committed Rust file (which the
# scenario of build --check checks), as a user's first build is: the library goes to native/libmath.so, the entry is
# added at the end of agentica.toml, and what it prints and adds are the docs' blocks.
rm "$pkg/rust/src/math_native.rs"
(cd "$pkg" && agentica "$cli" build math.agc) > "$pkg/first.txt"
same "The output of \`build\` on Linux (cargo prints its progress on stderr):" "$pkg/first.txt"
tail -n 2 "$pkg/agentica.toml" > "$pkg/entry.txt"
same "The entry that \`build\` adds to \`agentica.toml\`:" "$pkg/entry.txt"
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

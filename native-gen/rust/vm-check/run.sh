#!/bin/sh
# Builds the vm-check module (Linux), runs check.agc on it with the heap floor off (so collections run during the
# calls), and compares its output with expected.txt. Needs cargo and agentica on PATH.
set -eu
cd "$(dirname "$0")"
cargo build --release --quiet
mkdir -p native
cp target/release/libvm_check.so native/
# The manifest that points at the library, made here: committed, it would make `agentica check` of native-gen fail
# where the library was not built.
printf 'name = "vm-check"\n\n[native.vm_check]\nlinux = { file = "native/libvm_check.so" }\n' > agentica.toml
AGENTICA_GC_HEAP=0 agentica check.agc > target/out.txt
diff -u expected.txt target/out.txt
echo "vm-check: ok"

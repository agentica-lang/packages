#!/bin/sh
# Builds the vm-check module (Linux), runs check.agc on it, and compares its output with expected.txt; the last call
# must fail with the arity check of make_struct. Needs cargo and agentica on PATH.
set -eu
cd "$(dirname "$0")"
cargo build --release --quiet
mkdir -p native
cp target/release/libvm_check.so native/
# The manifest that points at the library, made here: committed, it would make `agentica check` of native-gen fail
# where the library was not built.
printf 'name = "vm-check"\n\n[native.vm_check]\nlinux = { file = "native/libvm_check.so" }\n' > agentica.toml
status=0
AGENTICA_GC_HEAP=0 agentica check.agc > target/out.txt 2> target/err.txt || status=$?
diff -u expected.txt target/out.txt
if [ "$status" -ne 1 ] || ! grep -q "bad_point: make_struct: row 0 does not take 1 fields" target/err.txt; then
  echo "vm-check: expected bad_point to fail the call (exit $status)" >&2
  cat target/err.txt >&2
  exit 1
fi
echo "vm-check: ok"

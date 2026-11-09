#!/bin/sh
# Builds the vm-check module (Linux), runs check.agc on it with the heap floor off (so collections run during the
# calls), and compares its output with expected.txt; the last call must fail with the arity check of make_struct.
# failing.agc must fail with the caught panic of its call, and with its Raise when given an argument.
# Needs cargo and agentica on PATH.
set -eu
cd "$(dirname "$0")"
cargo build --release --quiet
mkdir -p native
cp target/release/libvm_check.so native/
# The manifest that points at the library, made here: committed, it would make `agentica check` of native-gen fail
# where the library was not built.
printf 'name = "vm-check"\n\n[native.vm_check]\nlinux = { file = "native/libvm_check.so" }\n' > agentica.toml
# fails PROGRAM TEXT [ARG]: PROGRAM must exit 1 with TEXT in its stderr.
fails() {
  status=0
  AGENTICA_GC_HEAP=0 agentica "$1" ${3:-} > target/out.txt 2> target/err.txt || status=$?
  if [ "$status" -ne 1 ] || ! grep -q "$2" target/err.txt; then
    echo "vm-check: expected $1 ${3:-} to fail with \"$2\" (exit $status)" >&2
    cat target/err.txt >&2
    exit 1
  fi
}
fails check.agc "bad_point: make_struct: row 0 does not take 1 fields"
diff -u expected.txt target/out.txt
fails failing.agc "checked: panic: zero is not checked"
fails failing.agc "checked: -1 is negative" raise
echo "vm-check: ok"

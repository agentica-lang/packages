#!/bin/sh
# Fetches the yaml-test-suite cases that specs/suite.feature runs: the GitHub archive of a pinned commit of the
# suite's data branch, checked against its sha256 and unpacked into .cache/ of the package. A cache that is already
# there is kept. `make install PACKAGES=yaml` runs it.
set -eu

COMMIT=6ad3d2c62885d82fc349026c136ef560838fdf3d
SHA256=797af50e3f9321f9fd40f8457f8f12f56108c1580653456dca2064cd3c298a8a
URL="https://github.com/yaml/yaml-test-suite/archive/$COMMIT.tar.gz"

cd "$(dirname "$0")/.."
target=".cache/yaml-test-suite-$COMMIT"
[ -d "$target" ] && exit 0

mkdir -p .cache
work=$(mktemp -d .cache/fetch.XXXXXX)
trap 'rm -rf "$work"' EXIT
curl -sSfL --retry 3 -o "$work/suite.tar.gz" "$URL"
echo "$SHA256  $work/suite.tar.gz" | sha256sum -c --quiet -
mkdir "$work/suite"
tar -xzf "$work/suite.tar.gz" -C "$work/suite" --strip-components=1
mv "$work/suite" "$target"
echo "yaml-test-suite $COMMIT in yaml/$target"

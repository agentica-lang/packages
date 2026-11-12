#!/bin/sh
# Prints the absolute path of the Agentica binary that runs the package folder $1, at the version of its
# AGENTICA_VERSION file (one line: the version, then the sha256 of its linux-x86_64 archive, which only CI reads).
#
# The binary is the first of:
# - $AGENTICA_HOME/agentica-VERSION-PLATFORM/bin/agentica, where PLATFORM is this machine's as the release archives
#   name it (from `uname -sm`), and AGENTICA_HOME defaults to ~/.local/share/agentica, where releases unpack side by
#   side;
# - agentica on PATH when `agentica --version` prints VERSION (CI puts the version of each job there).
# Any other agentica is an error: a package never runs on a version it did not declare. The binary is always named
# `agentica`, so the Makefile puts its folder first on PATH, and a program that a test starts (`agentica` by name) runs
# on the same version. The path is absolute because the Makefile runs the binary from inside the package folder.
set -eu

package=${1:?usage: tools/agentica-for.sh PACKAGE}
file="$package/AGENTICA_VERSION"
[ -f "$file" ] || { echo "$file: missing; it names the Agentica version of $package" >&2; exit 1; }
version=$(awk 'NR == 1 { print $1 }' "$file")
[ -n "$version" ] || { echo "$file: empty; its line is the version, then the sha256" >&2; exit 1; }

absolute() {
  case $1 in
    /*) echo "$1" ;;
    *) echo "$PWD/$1" ;;
  esac
}

case $(uname -sm) in
  "Linux x86_64") platform=linux-x86_64 ;;
  "Linux aarch64" | "Linux arm64") platform=linux-arm64 ;;
  "Darwin x86_64") platform=macos-x86_64 ;;
  "Darwin arm64") platform=macos-arm64 ;;
  *) platform= ;;
esac
home=${AGENTICA_HOME:-$HOME/.local/share/agentica}
bin="$home/agentica-$version-$platform/bin/agentica"
if [ -n "$platform" ] && [ -x "$bin" ]; then absolute "$bin"; exit 0; fi
if bin=$(command -v agentica) && [ "$("$bin" --version)" = "$version" ]; then absolute "$bin"; exit 0; fi
echo "$package needs Agentica $version ($file): unpack its release in $home" \
  "or put that version first on PATH" >&2
exit 1

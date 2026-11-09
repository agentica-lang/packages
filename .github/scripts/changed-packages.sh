#!/usr/bin/env bash
# Prints the packages (folders with an agentica.toml) that CI must run, space separated, for the changed files read
# from stdin as NUL-separated names (git diff --name-only --no-renames -z: a rename lists both paths, and git does not
# quote odd names). `--all` prints every package.
#
# - A file under PKG/ marks PKG, except PKG/README.md and PKG/CHANGELOG.md: they hold no code. PKG/docs/ marks PKG,
#   since `make doc-examples` runs its examples (pages.yml builds the pages).
# - README.md, AGENTS.md, site/ and pages.yml at the root mark none.
# - Any other file outside a package (Makefile, ci.yml, .github/scripts/, .github/actions/, a shared config) marks all
#   of them: an unknown file is safer to treat as shared.
# - A package stands alone (AGENTS.md), so no package depends on another folder of this repo and a change never
#   marks a package it does not touch. If that rule changes, a dependent package must be added here.
set -euo pipefail
shopt -s nullglob
cd "$(dirname "$0")/../.."

all_packages() {
  local f
  for f in */agentica.toml; do echo "${f%/agentica.toml}"; done
}

if [ "${1:-}" = "--all" ]; then
  all_packages | paste -sd' '
  exit 0
fi

declare -A marked=()
everything=0
while IFS= read -r -d '' file; do
  top=${file%%/*}
  if [ "$top" != "$file" ] && [ -f "$top/agentica.toml" ]; then
    case ${file#*/} in
      README.md | CHANGELOG.md) ;;
      *) marked[$top]=1 ;;
    esac
    continue
  fi
  case $file in
    README.md | AGENTS.md | site/* | .github/workflows/pages.yml) ;;
    *) everything=1 ;;
  esac
done

if [ "$everything" = 1 ]; then
  all_packages | paste -sd' '
elif [ "${#marked[@]}" -gt 0 ]; then
  printf '%s\n' "${!marked[@]}" | sort | paste -sd' '
else
  echo
fi

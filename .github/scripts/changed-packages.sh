#!/usr/bin/env bash
# Prints the packages (folders with an agentica.toml) that CI must run, space separated, for the changed files read
# from stdin as NUL-separated names (git diff --name-only --no-renames -z: a rename lists both paths, and git does not
# quote odd names). `--all` prints every package. `--docs` prints instead the packages whose only change is in their
# docs/: CI runs only their doc examples.
#
# - A file under PKG/ marks PKG, except PKG/README.md and PKG/CHANGELOG.md: they hold no code. A file of PKG/docs/
#   marks PKG for `--docs` alone, since `make doc-examples` runs its examples (pages.yml builds the pages); any other
#   file of PKG marks it for everything.
# - README.md, AGENTS.md, LICENSE, site/, .gitmodules (the docs theme of site/) and pages.yml at the root mark none.
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
docs_mode=0
if [ "${1:-}" = "--docs" ]; then docs_mode=1; fi

declare -A marked=() docs=()
everything=0
while IFS= read -r -d '' file; do
  top=${file%%/*}
  if [ "$top" != "$file" ] && [ -f "$top/agentica.toml" ]; then
    case ${file#*/} in
      README.md | CHANGELOG.md) ;;
      docs/*) docs[$top]=1 ;;
      *) marked[$top]=1 ;;
    esac
    continue
  fi
  case $file in
    README.md | AGENTS.md | LICENSE | site/* | .gitmodules | .github/workflows/pages.yml) ;;
    *) everything=1 ;;
  esac
done

if [ "$docs_mode" = 1 ]; then
  only_docs=()
  if [ "$everything" = 0 ]; then
    for p in "${!docs[@]}"; do [ -n "${marked[$p]:-}" ] || only_docs+=("$p"); done
  fi
  if [ "${#only_docs[@]}" -gt 0 ]; then printf '%s\n' "${only_docs[@]}" | sort | paste -sd' '; else echo; fi
elif [ "$everything" = 1 ]; then
  all_packages | paste -sd' '
elif [ "${#marked[@]}" -gt 0 ]; then
  printf '%s\n' "${!marked[@]}" | sort | paste -sd' '
else
  echo
fi

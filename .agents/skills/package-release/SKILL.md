---
name: package-release
description: "Release an agentica-lang/packages package (PKG-X.Y.Z): release branch with CHANGELOG/README/docs tag bumps, release PR, merge, tag push, and GitHub Release. Use when the user asks to release, tag, or publish a package version; not for ordinary feature PRs (dev-workflow) or review replies (address-review-gh)."
---

# Release a package

Release flow for one package of `agentica-lang/packages`, where the git tag
is the release mechanism (`agentica add --tag` resolves tags, not GitHub
Releases). Inputs: `PACKAGE` folder, `X.Y.Z` (patch/minor/major per semver and
Keep a Changelog), repo clean and on `main`.

## Procedure

1. Confirm the base: `git checkout main`, `git pull --ff-only`. Work starts at
   the merge of the feature PR.
2. Create `git checkout -b release-PACKAGE-X.Y.Z`.
3. `PACKAGE/CHANGELOG.md`: rename `## [Unreleased]` in place to
   `## [X.Y.Z] - DATE` with DATE as UTC `YYYY-MM-DD`. Do not add a fresh empty
   `## [Unreleased]`; follow the 0.3.0 precedent.
4. Top-level `README.md` table row: bump the `` `PACKAGE` (`PACKAGE-old`) ``
   tag and refresh the one-line description when behavior changed. Site prose
   stays one line per item.
5. `PACKAGE/docs/_index.md`: bump the tag in the `sh` install block and the
   `toml` block. The `agentica` code blocks are executed by `doc-examples`,
   but `sh`/`toml` blocks are not; the Agentica-version line only changes on a
   runtime bump.
6. Validate with that package's binary (`tools/agentica-for.sh PACKAGE`):
   `agentica fmt --check`, `agentica check`. A release touches no `.agc`, so
   this is a formality before CI runs the docs-only job.
7. Commit (`Release PACKAGE X.Y.Z` plus bullets: what is recorded, install
   commands updated), push the branch, open the PR against `main`.
8. Wait for green CI (`gh pr checks`), then merge with `--merge` (this repo
   merges, it does not squash).
9. Back on `main`: pull, verify the CHANGELOG section, then
   `git tag PACKAGE-X.Y.Z` and push the tag. A PR never pushes a tag.
10. Publish the GitHub Release with `gh release create TAG --verify-tag --title "PACKAGE X.Y.Z" --notes-file FILE`.
    `FILE` must contain the nonempty version section from `git show TAG:PACKAGE/CHANGELOG.md`, not `Unreleased`.
    Do not create an empty release or automate publication on tag push. Leave old gaps alone unless asked; then
    publish at most the latest stable tag per requested package.
    The latest-tag column of the site's home table reads the git tags at build time, so after the tag push run
    `gh workflow run pages.yml` (it rebuilds and deploys main).
11. If asked to clean up, delete the merged local release branch with `git branch -d`.

## Auth and boundaries

- `gh` may need more permission than the default token. Use
  `GITHUB_PAT_AGENTICA` via `GH_TOKEN=...` (verify with `gh auth status`;
  never print the token, check only that the variable is set).
- Merge, tag push, and Release creation are owner/coordinator actions: the
  author always tells the agent to do the release; never start one
  unprompted. Do them only on explicit user go-ahead, and report the PR
  number, merge commit, and tag afterwards.
- If CI is red, stop at the merge step and report; do not substitute local
  runs for required checks.

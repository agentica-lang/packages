---
title: Prebuilt native modules
description: A reusable GitHub workflow that builds a native module on the five targets and uploads the files of its prebuilt table.
---

A package with a native module (`[native.NAME]` with a `build` table in `agentica.toml`) can ship one prebuilt library per target, so that its users need no C compiler. The reusable workflow [`native-prebuilt.yml`](https://github.com/agentica-lang/packages/blob/main/.github/workflows/native-prebuilt.yml) of this repository makes those files:

- it builds the module on the five targets with the toolchains of Agentica's own releases: zig cc against glibc 2.28 on `linux-x86_64` and `linux-arm64`, Apple clang with `MACOSX_DEPLOYMENT_TARGET=12.0` on `macos-x86_64` and `macos-arm64`, and MSYS2 UCRT64 gcc on `windows-x86_64`;
- the compiler gets the same arguments as Agentica's own build of the `build` table, then `extra-args`, and the library is stripped;
- it checks each library: glibc 2.28 at most on Linux, `minos` 12.0 on macOS, only Windows and UCRT DLLs on Windows, and one export, `agentica_native_init`; then it loads it in a plain process;
- it runs `agentica native source NAME` and uploads `lib{name}-{api}-{target}{ext}` to the release `native-<source>` of your repository, which it creates when it is missing (on the tag `native-<source>` when that exists, else at the commit of the run);
- it prints the `prebuilt` row with its `sha256` table, ready to paste under `[native.NAME]`, in the job summary.

The files are named by the source key, which covers the `build` table and the files of `native/`. When the committed `agentica.toml` has a `prebuilt` row with this key, the row pins the release: each file it names must be there with its `sha256`, or the run fails, and the files are kept. A target the row leaves out, or every target when there is no row, gets the fresh build, which replaces a file of the same name. The job summary always shows the row of the fresh build, and after an upload the row of the release.

## Use

Call it from a workflow of your repository, pinned by commit. The build jobs read only; the upload job takes the permissions of your job, and uploading needs `contents: write`. Give a pull request a job of its own with `dry-run: true` and `contents: read`:

```yaml
on:
  push:
    tags: ['native-*']
  pull_request:
    paths: ['native/**', 'agentica.toml']
  workflow_dispatch:

permissions:
  contents: read

jobs:
  check:
    if: github.event_name == 'pull_request'
    uses: agentica-lang/packages/.github/workflows/native-prebuilt.yml@COMMIT
    with:
      module: db_sqlite
      agentica-version: 0.34.0
      agentica-sha256: SHA256_OF_THE_LINUX_X86_64_ARCHIVE
      dry-run: true

  upload:
    if: github.event_name != 'pull_request'
    permissions:
      contents: write
    uses: agentica-lang/packages/.github/workflows/native-prebuilt.yml@COMMIT
    with:
      module: db_sqlite
      agentica-version: 0.34.0
      agentica-sha256: SHA256_OF_THE_LINUX_X86_64_ARCHIVE
```

A run by hand can build any branch once the workflow file is on the default branch: `gh workflow run native-prebuilt.yml --ref BRANCH`. A push of the tag `native-<source>` runs it too (`agentica native source NAME` prints the key): a run on a tag `native-*` that is not the key of its sources fails before it uploads.

Then commit the printed row, for example:

```toml
[native.db_sqlite]
build = { sources = ["native/db_sqlite.c"] }
prebuilt = { url = "https://github.com/OWNER/REPO/releases/download/native-{source}/lib{name}-{api}-{target}{ext}", source = "…", api = "1.4", sha256 = { linux-x86_64 = "…", linux-arm64 = "…", macos-x86_64 = "…", macos-arm64 = "…", windows-x86_64 = "…" } }
```

Adding the row does not change the source key, since the key covers only the `build` table and `native/`.

## Inputs

| Input | What it is |
|---|---|
| `module` | The `NAME` of `[native.NAME]` (required). |
| `directory` | The folder of `agentica.toml`, `.` by default. |
| `agentica-version`, `agentica-sha256` | The Agentica release that builds, and the sha256 of its `linux-x86_64` archive from its `SHA256SUMS`. The header and the native API come from it. |
| `agentica-commit` | Instead of a release, a full commit SHA of `agentica-lang/agentica`, built in the job. |
| `prepare` | A bash command run in `directory` before each build, such as a script that fetches a pinned source. `$PYTHON` names a Python 3 on every runner. |
| `extra-args` | Compiler arguments after those of the `build` table, split at spaces with no quoting, such as `-DSTATIC third_party/lib.c`. |
| `dry-run` | `true` builds and prints the row, but uploads nothing. |

The outputs are `source`, `api` and `prebuilt` (the row).

Only `native/` and the `build` table make the source key. `prepare` must not change them (the run fails if `git status` shows a change there), and a source it fetches, `extra-args` or a new toolchain gives new files only with a change to `native/`: write the pin of a fetched source (its version and hash) in a file of `native/`.

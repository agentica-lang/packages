---
title: Prebuilt native modules
description: A reusable GitHub workflow that builds a native module on the five targets and uploads the files of its prebuilt table.
---

A package with a native module (`[native.NAME]` with a `build` table in `agentica.toml`) can ship one prebuilt library per target, so that its users need no C compiler. The reusable workflow [`native-prebuilt.yml`](https://github.com/agentica-lang/packages/blob/main/.github/workflows/native-prebuilt.yml) of this repository makes those files:

- it builds the module on the five targets with the toolchains of Agentica's own releases: zig cc against glibc 2.28 on `linux-x86_64` and `linux-arm64`, Apple clang with `MACOSX_DEPLOYMENT_TARGET=12.0` on `macos-x86_64` and `macos-arm64`, and MSYS2 UCRT64 gcc on `windows-x86_64`;
- the compiler gets the same arguments as Agentica's own build of the `build` table, then `extra-args`, and the library is stripped;
- it checks that each library loads in a plain process;
- it runs `agentica native source NAME` and uploads `lib{name}-{api}-{target}{ext}` to the release `native-<source>` of your repository, which it creates when it is missing (on the tag `native-<source>` when that exists, else at the commit of the run);
- it prints the `prebuilt` row with its `sha256` table, ready to paste under `[native.NAME]`, in the job summary.

The files are named by the source key, which covers the `build` table and the files of `native/`. A release whose native sources did not change finds the files there: it keeps them and prints their table again. A file that the release already has is never replaced.

## Use

Call it from a workflow of your repository, pinned by commit. Uploading needs `contents: write`:

```yaml
on:
  push:
    tags: ['native-*']
  workflow_dispatch:

jobs:
  prebuilt:
    permissions:
      contents: write
    uses: agentica-lang/packages/.github/workflows/native-prebuilt.yml@COMMIT
    with:
      module: db_sqlite
      agentica-version: 0.34.0
      agentica-sha256: SHA256_OF_THE_LINUX_X86_64_ARCHIVE
```

A workflow file runs by hand (`workflow_dispatch`) only from the default branch. To make the files of a branch first, run the workflow on a push of the tag `native-<source>` (`agentica native source NAME` prints the key): a run on a tag `native-*` that is not the key of its sources fails before it uploads.

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

A source that `prepare` fetches is not in `native/`, so it is not in the source key: to make a new pin give new files, write the pin (its version and hash) in a file of `native/`.

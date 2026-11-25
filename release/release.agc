## A release of an Agentica app: a folder that holds the `agentica` binary, the compiled program, a launcher and a
## manifest, so that it runs on another machine of the same system and architecture with nothing else installed.
## `build` makes the folder, `tar` packs it, and `inspect` checks a folder or an archive against its manifest. The
## command line is `cli.agc`. Native libraries stored by path are refused until Agentica can move them.

import Build from "src/build"
import Layout from "src/layout"
import Verify from "src/verify"

export Build.Options
export Build.Built
export Layout.Manifest
export Layout.Entry

## The release folder `OUT/NAME-VERSION` of the project in `options.project`.
def build(options: Build.Options) -> Result[Build.Built] = Build.build(options)

## The archive of a release folder, written beside it. Gives its path.
def tar(folder: String) -> Result[String] = Verify.tar(folder)

## The manifest of a release folder or `.tar.gz`, once every file matches it.
def inspect(path: String) -> Result[Layout.Manifest] = Verify.inspect(path)

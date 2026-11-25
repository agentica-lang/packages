## The command line of release. `build [PROJECT]` makes the release folder of a project (the one in the current folder
## by default), `tar FOLDER` packs a release folder, and `inspect FOLDER|ARCHIVE` checks one against its manifest.
##
## ```sh
## agentica deps/release/cli.agc build --out _release
## agentica deps/release/cli.agc tar _release/app-1.0.0
## agentica deps/release/cli.agc inspect _release/app-1.0.0-linux-x86_64.tar.gz
## ```
##
## Exit 0 on success, 1 on an error, 2 on bad usage. An error is one line on stderr, `release: message`.

import Release from "release"
import OP from "std/option_parser"
import {Arg, Kind, Opt} from "std/option_parser"

private

PROGRAM = "release"

def main() -> Void
  args = System.args()
  if args.empty? or !["build", "tar", "inspect"].include?(args[0])
    IO.warn("usage: #{PROGRAM} build|tar|inspect ... (#{PROGRAM} COMMAND --help)")
    System.exit(2)
  end

  done = ok()
  if args[0] == "build"
    done = built(OP.run!(build_options(args.drop(1))))
  elsif args[0] == "tar"
    done = packed(
      OP.run!(path_options("tar", "Packs a release folder as NAME-VERSION-OS-ARCH.tar.gz beside it.", args.drop(1))),
    )
  else
    done = inspected(
      OP.run!(path_options("inspect", "Checks a release folder or .tar.gz against its manifest.", args.drop(1))),
    )
  end

  if !done.ok?
    IO.warn(done.message)
    System.exit(1)
  end
end

def build_options(args: List[String]) -> Result[Release.Options]
  parser = OP.new(
    "#{PROGRAM} build",
    "Builds the release folder OUT/NAME-VERSION of a project: the agentica binary, the compiled program and a launcher.",
    [],
    [
      Opt(name: "out", short: "o", help: "the folder that gets NAME-VERSION (default: _release)"),
      Opt(name: "agentica", help: "the agentica binary to compile with and to ship (default: the one on PATH)"),
      Opt(name: "version", help: "the version of the release (default: version of [tool.release])"),
      Opt(name: "entry", help: "the program to compile (default: entry of [tool.release], else main.agc)"),
    ],
    "[PROJECT]",
  )

  p = try OP.parse(parser, args)
  project = "."
  if !OP.rest(p).empty?
    project = OP.rest(p)[0]
  end

  ok(
    Release.Options(
      project: project,
      out: OP.optional_string(p, "out").unwrap_or("_release"),
      agentica: OP.optional_string(p, "agentica").unwrap_or(""),
      version: OP.optional_string(p, "version").unwrap_or(""),
      entry: OP.optional_string(p, "entry").unwrap_or(""),
    ),
  )
end

def path_options(command: String, help: String, args: List[String]) -> Result[String]
  parser = OP.new("#{PROGRAM} #{command}", help, [Arg(name: "path", help: "the release folder or archive")], [])
  p = try OP.parse(parser, args)
  ok(OP.string(p, "path"))
end

def built(options: Release.Options) -> Result[Void]
  done = try Release.build(options)
  puts("release: built #{done.path} (#{done.manifest.files.size} files, agentica #{done.manifest.agentica})")
  for library in done.system_libraries
    puts("release: the target must have #{library}")
  end

  ok()
end

def packed(folder: String) -> Result[Void]
  puts("release: wrote #{try Release.tar(folder)}")
  ok()
end

def inspected(path: String) -> Result[Void]
  manifest = try Release.inspect(path)
  puts(
    "release: #{manifest.name} #{manifest.version} for #{manifest.os} #{manifest.arch}, agentica #{manifest.agentica}, #{manifest.files.size} files match",
  )

  ok()
end

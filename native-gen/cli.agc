## The command line of native-gen: writes the C header of the `extern module` block of FILE (or with `--lang rust`
## its Rust file), or with `--check` fails when the file at `--output` is not the one FILE gives. `new PATH` writes a
## new module instead: `PATH.agc`, its C file and header in `native/`, and its entry in `agentica.toml`. `build FILE`
## builds the Rust module of FILE from the crate `rust/` at its package root, into `native/` (with `--check`, it only
## fails when the Rust file is stale).
##
## ```sh
## agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h
## agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
## agentica deps/native-gen/cli.agc stats.agc --lang rust --output src/stats_native.rs
## agentica deps/native-gen/cli.agc new demo
## agentica deps/native-gen/cli.agc build stats.agc
## ```
##
## Exit 0 on success, 1 on an error of the file or a stale header, 2 on bad usage. An error is one line on stderr,
## `native-gen: [CODE] message`.

import NativeGen from "native_gen"
import OP from "std/option_parser"
import {Arg, Kind, Opt} from "std/option_parser"

PROGRAM = "native-gen"

struct BuildOptions
  file: String
  check: Bool
end

struct Options
  file: String
  prefix: String
  output: String
  check: Bool
  lang: String
end

def main() -> Void
  args = System.args()
  done = ok()
  if !args.empty? and args[0] == "new"
    done = NativeGen.scaffold(OP.run!(new_path(args.drop(1))))
  elsif !args.empty? and args[0] == "build"
    done = built(OP.run!(build_options(args.drop(1))))
  else
    done = run(OP.run!(parsed(args)))
  end

  if !done.ok?
    IO.warn("#{PROGRAM}: #{done.message}")
    System.exit(1)
  end
end

def parsed(args: List[String]) -> Result[Options]
  parser = OP.new(
    PROGRAM,
    "Writes the C header (or the Rust file) of the extern module block of FILE.",
    [Arg(name: "file", help: "the .agc file with the extern module block")],
    [
      Opt(name: "prefix", help: "the start of the C names, or of the Rust trait (default: the library name up to .)"),
      Opt(name: "output", short: "o", help: "the file to write (default: stdout)"),
      Opt(
        name: "check",
        kind: Kind.Flag,
        help: "write nothing; fail when the --output file is not the one FILE gives",
      ),
      Opt(name: "lang", help: "c (the default) for the C header, rust for the Rust file of the agentica-native crate"),
    ],
  )

  p = try OP.parse(parser, args)
  options = Options(
    file: OP.string(p, "file"),
    prefix: OP.optional_string(p, "prefix").unwrap_or(""),
    output: OP.optional_string(p, "output").unwrap_or(""),
    check: OP.flag(p, "check"),
    lang: OP.optional_string(p, "lang").unwrap_or("c"),
  )

  if options.lang != "c" and options.lang != "rust"
    return error("#{PROGRAM}: --lang is c or rust, not #{options.lang.inspect}\nTry '#{PROGRAM} --help'")
  end

  if options.check and options.output.empty?
    return error("#{PROGRAM}: --check needs --output\nTry '#{PROGRAM} --help'")
  end

  return ok(options)
end

# The PATH of `new PATH`.
def new_path(args: List[String]) -> Result[String]
  parser = OP.new(
    "#{PROGRAM} new",
    "Writes a new native module: PATH.agc, native/NAME.c, its header, and its entry in agentica.toml.",
    [Arg(name: "path", help: "the module, NAME or FOLDER/NAME")],
    [],
  )

  p = try OP.parse(parser, args)
  return ok(OP.string(p, "path"))
end

# The FILE and --check of `build FILE`.
def build_options(args: List[String]) -> Result[BuildOptions]
  parser = OP.new(
    "#{PROGRAM} build",
    "Builds the Rust module of FILE from the crate rust/ at its package root into native/, with cargo.",
    [Arg(name: "file", help: "the .agc file with the extern module block")],
    [Opt(name: "check", kind: Kind.Flag, help: "run no cargo; fail when the Rust file is not the one FILE gives")],
  )

  p = try OP.parse(parser, args)
  return ok(BuildOptions(file: OP.string(p, "file"), check: OP.flag(p, "check")))
end

def built(options: BuildOptions) -> Result[Void]
  lines = try NativeGen.build(options.file, options.check)
  lines.each do |line| puts(line) end
  return ok()
end

def run(options: Options) -> Result[Void]
  text = ""
  if options.lang == "rust"
    text = try NativeGen.rust(options.file, options.prefix)
  else
    text = try NativeGen.header(options.file, options.prefix)
  end

  if options.output.empty?
    print(text)
    return ok()
  end

  if !options.check
    return written(options.output, File.write_text(options.output, text))
  end

  case File.read_text(options.output)
    ok(kept) if kept == text -> return ok()
    ok(_) -> return error("[NATIVE-GEN-STALE] #{options.output} is not the one #{options.file} gives; make it again")
    error(message) -> return error("[NATIVE-GEN-IO] #{options.output}: #{message}")
  end
end

def written(path: String, done: Result[Void]) -> Result[Void]
  if !done.ok?
    return error("[NATIVE-GEN-IO] #{path}: #{done.message}")
  end

  return ok()
end

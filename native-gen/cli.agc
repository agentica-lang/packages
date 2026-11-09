## The command line of native-gen: writes the C header of the `extern module` block of FILE, or with `--check` fails
## when the header at `--output` is not the one FILE gives. `new PATH` writes a new module instead: `PATH.agc`, its C
## file and header in `native/`, and its entry in `agentica.toml`.
##
## ```sh
## agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h
## agentica deps/native-gen/cli.agc stats.agc --output native/stats_native.h --check
## agentica deps/native-gen/cli.agc new demo
## ```
##
## Exit 0 on success, 1 on an error of the file or a stale header, 2 on bad usage. An error is one line on stderr,
## `native-gen: [CODE] message`.

import NativeGen from "native_gen"
import OP from "std/option_parser"
import {Arg, Kind, Opt} from "std/option_parser"

PROGRAM = "native-gen"

struct Options
  file: String
  prefix: String
  output: String
  check: Bool
end

def main() -> Void
  args = System.args()
  done = ok()
  if !args.empty? and args[0] == "new"
    done = NativeGen.scaffold(OP.run!(new_path(args.drop(1))))
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
    "Writes the C header of the extern module block of FILE.",
    [Arg(name: "file", help: "the .agc file with the extern module block")],
    [
      Opt(name: "prefix", help: "the start of the C names (default: the library name up to its first .)"),
      Opt(name: "output", short: "o", help: "the header file to write (default: stdout)"),
      Opt(name: "check", kind: Kind.Flag, help: "write nothing; fail when the --output file is not the header"),
    ],
  )

  p = try OP.parse(parser, args)
  options = Options(
    file: OP.string(p, "file"),
    prefix: OP.optional_string(p, "prefix").unwrap_or(""),
    output: OP.optional_string(p, "output").unwrap_or(""),
    check: OP.flag(p, "check"),
  )

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

def run(options: Options) -> Result[Void]
  text = try NativeGen.header(options.file, options.prefix)
  if options.output.empty?
    print(text)
    return ok()
  end

  if !options.check
    return written(options.output, File.write_text(options.output, text))
  end

  case File.read_text(options.output)
    ok(kept) if kept == text -> return ok()
    ok(_) -> return error("[NATIVE-GEN-STALE] #{options.output} is not the header of #{options.file}; make it again")
    error(message) -> return error("[NATIVE-GEN-IO] #{options.output}: #{message}")
  end
end

def written(path: String, done: Result[Void]) -> Result[Void]
  if !done.ok?
    return error("[NATIVE-GEN-IO] #{path}: #{done.message}")
  end

  return ok()
end

## The C header of the `extern module` block of an `.agc` file: typed prototypes for the C author, and the wrappers
## and tables of the module, which the C file includes once with `PREFIX_NATIVE_IMPLEMENTATION` defined.
##
## ```ruby
## import NativeGen from "pkg/native-gen/native_gen"
##
## text = try NativeGen.header("stats.agc")
## ```
##
## An error starts with its code in brackets: `[NATIVE-GEN-NAME] ...` when two names map to one C identifier,
## `[NATIVE-GEN-PREFIX]`, `[NATIVE-GEN-BLOCK]`, `[NATIVE-GEN-UNKNOWN]`, `[NATIVE-GEN-EXISTS]`,
## `[NATIVE-GEN-MANIFEST]`, `[NATIVE-GEN-IO]`, or the code of the diagnostic when the file does not check.

import Analysis from "std/analysis"
import Toml from "std/toml"
import CHeader from "src/header"
import Scaffold from "src/scaffold"

## The header of the one `extern module` block of the file at `path`. Its C names start with `prefix`, by default the
## last part of the block's library name up to its first `.` (`stats` for "stats" and for "native/stats.so").
export def header(path: String, prefix: String = "") -> Result[String]
  return header_in(Analysis.workspace(), path, prefix)
end

## A new native module at `path` (`demo`, or `pkg/demo` in the folder `pkg`): writes `NAME.agc` with an `extern
## module "NAME"` block, `native/NAME.c` with a body per function that fails the call until it is written, the header
## made from the `.agc`, and the `[native.NAME]` entry of the folder's `agentica.toml`, which it makes when there is
## none. It writes nothing when one of those files, or the entry, is there already (`[NATIVE-GEN-EXISTS]`).
export def scaffold(path: String) -> Result[Void]
  name = last_part(path)
  folder = path.slice(0, path.length - name.length)
  if folder.empty?
    folder = "./"
  end

  problem = Scaffold.name_problem(name)
  prefix = CHeader.prefix(name)
  if problem.empty? and !prefix.ok?
    problem = prefix.message
  end

  if !problem.empty?
    return error("[NATIVE-GEN-PREFIX] #{name.inspect}: #{problem}; pass NAME or FOLDER/NAME, without .agc")
  end

  names = prefix.unwrap!
  program = "#{folder}#{name}.agc"
  source = "#{folder}native/#{name}.c"
  header_path = "#{folder}native/#{names.lower}_native.h"
  manifest = "#{folder}agentica.toml"
  for kept in [program, source, header_path]
    if File.stat(kept).ok?
      return error("[NATIVE-GEN-EXISTS] #{kept} is there already; native-gen new writes only new files")
    end
  end

  # Every text is made before the first write, the header from the new .agc as a buffer, so a refusal, or a failure
  # while making them, leaves the folder as it was; a write that fails midway leaves the files written before it.
  toml = try manifest_with(manifest, name, Scaffold.entry(name, names))
  text = Scaffold.program(name)
  made = try header_in(Analysis.Workspace(version: 1, buffers: {program: text}), program, "")
  try io("#{folder}native", Dir.mkdir("#{folder}native"))
  try io(program, File.write_text(program, text))
  try io(source, File.write_text(source, Scaffold.source(name, names)))
  try io(header_path, File.write_text(header_path, made))
  return io(manifest, File.write_text(manifest, toml))
end

# The header of the file at `path` as `files` has it: the disk, or a buffer in place of the file.
def header_in(files: Analysis.Workspace, path: String, prefix: String) -> Result[String]
  case Analysis.native_modules(Analysis.open(files), path)
    ok(found) -> return header_of(found.blocks, path, prefix)
    error(message) -> return error(diagnostic_text(message))
  end
end

# The text of the manifest at `path` with `entry` at its end, or a new one named `name`. An entry of `name` there
# already is `[NATIVE-GEN-EXISTS]`; a manifest that is not TOML, before or after, is `[NATIVE-GEN-MANIFEST]`.
def manifest_with(path: String, name: String, entry: String) -> Result[String]
  toml = "name = #{name.inspect}\n"
  if File.stat(path).ok?
    toml = try io(path, File.read_text(path))
    doc = try manifest_parsed(path, toml)
    if Toml.get(doc, "native.#{name}").ok?
      return error("[NATIVE-GEN-EXISTS] #{path} has native.#{name} already")
    end
  end

  if !toml.empty? and !toml.end_with?("\n")
    toml = "#{toml}\n"
  end

  joined = "#{toml}#{entry}"
  try manifest_parsed(path, joined)
  return ok(joined)
end

def manifest_parsed(path: String, text: String) -> Result[Toml.Value]
  case Toml.parse(text)
    ok(doc) -> return ok(doc)
    error(message) -> return error("[NATIVE-GEN-MANIFEST] #{path} with [native.NAME] added is not TOML: #{message}")
  end
end

# `done`, with an error of it as `[NATIVE-GEN-IO] PATH: message`.
def io[T](path: String, done: Result[T]) -> Result[T]
  case done
    ok(_) -> return done
    error(message) -> return error("[NATIVE-GEN-IO] #{path}: #{message}")
  end
end

def header_of(blocks: List[Analysis.NativeBlock], path: String, prefix: String) -> Result[String]
  if blocks.size != 1
    return error("[NATIVE-GEN-BLOCK] #{path} has #{blocks.size} extern module blocks; the header is made for one")
  end

  block = blocks[0]
  name = prefix
  if name.empty?
    name = default_prefix(block.library)
  end

  case CHeader.prefix(name)
    ok(names) -> return CHeader.render(block, names, last_part(path))
    error(message) -> return error("[NATIVE-GEN-PREFIX] #{message}; choose another with --prefix")
  end
end

# The first diagnostic of a file that does not check, as `[CODE] file:line:column message`.
def diagnostic_text(message: String) -> String
  case Analysis.diagnostic(message)
    ok(found) ->
      start = found.range.start
      return "[#{found.code}] #{found.file}:#{start.line}:#{start.column} #{found.message}"
    error(_) -> return message
  end
end

def default_prefix(library: String) -> String
  name = last_part(library)
  case name.index_of(".")
    some(at) -> return name.slice(0, at)
    none -> return name
  end
end

# The part of `path` after its last `/` or `\`.
def last_part(path: String) -> String
  parts = path.replace("\\", "/").split("/")
  return parts[parts.size - 1]
end

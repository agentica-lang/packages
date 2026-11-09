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
## `[NATIVE-GEN-PREFIX]`, `[NATIVE-GEN-BLOCK]`, `[NATIVE-GEN-UNKNOWN]`, `[NATIVE-GEN-EXISTS]`, `[NATIVE-GEN-MANIFEST]`,
## `[NATIVE-GEN-STALE]`, `[NATIVE-GEN-CARGO]`, `[NATIVE-GEN-OS]`, `[NATIVE-GEN-IO]`, or the code of the diagnostic
## when the file does not check.

import Analysis from "std/analysis"
import Toml from "std/toml"
import Build from "src/build"
import CHeader from "src/header"
import Names from "src/names"
import RustSide from "src/rust"
import Scaffold from "src/scaffold"

# How long cargo may build, and the bytes of one read of a copy.
CARGO_MS = 3_600_000
CHUNK = 1_048_576
# The most bytes that `File.replace` writes.
REPLACE_MAX = 16_777_216

## The header of the one `extern module` block of the file at `path`. Its C names start with `prefix`, by default the
## last part of the block's library name up to its first `.` (`stats` for "stats" and for "native/stats.so").
export def header(path: String, prefix: String = "") -> Result[String]
  return header_in(Analysis.workspace(), path, prefix)
end

## The Rust file of the one `extern module` block of the file at `path`, on the `agentica-native` crate: its types
## with their codecs, the trait the module implements and its tables. `prefix` names the trait, with its case kept
## (`StatsNative` for "stats", `MyDbNative` for "MyDb" or "my_db"); by default the one of `header`.
export def rust(path: String, prefix: String = "") -> Result[String]
  block = try block_in(Analysis.workspace(), path)
  return rust_of(block, prefix, path)
end

## Builds the Rust module of the file at `path` from the crate `rust/` at the root of its package, the nearest folder
## up from the file with an `agentica.toml`: writes its Rust file `rust/src/LIBRARY_native.rs` when it changed, runs
## `cargo build --release`, copies the library to the file of the `[native.LIBRARY]` entry of the root's
## `agentica.toml` for this system, and adds that entry when it is missing (`native/libLIBRARY.so` on linux). It gives
## one line per step, what it did or that it had nothing to do. With `check`, it only fails (`[NATIVE-GEN-STALE]`) when
## the Rust file is not the one the `.agc` gives.
export def build(path: String, check: Bool = false) -> Result[List[String]]
  root = try package_root(path)
  block = try block_in(Analysis.Workspace(version: 1, buffers: unbuilt(root)), path)
  name = block.library
  problem = Scaffold.name_problem(name)
  if !problem.empty?
    return error(
      "[NATIVE-GEN-BLOCK] build needs a library named as its [native.NAME], not #{name.inspect}: #{problem}",
    )
  end

  text = try rust_of(block, "", path)
  crate = "#{root}rust"
  source = "#{crate}/src/#{name}_native.rs"
  if check
    case File.read_text(source)
      ok(kept) if kept == text -> return ok([])
      ok(_) -> return error("[NATIVE-GEN-STALE] #{source} is not the one #{path} gives; run build")
      error(message) -> return error("[NATIVE-GEN-IO] #{source}: #{message}")
    end
  end

  if !File.stat("#{crate}/Cargo.toml").ok?
    return error("[NATIVE-GEN-IO] #{crate}/Cargo.toml: no Rust crate; build needs it in rust/ at the package root")
  end

  manifest = "#{root}agentica.toml"
  toml = try io(manifest, File.read_text(manifest))
  os = System.os()
  plan = try Build.plan(manifest, toml, name, os)
  extension = try Build.extension(os)
  done: List[String] = []
  if File.read_text(source).unwrap_or("") == text
    done = done.push("#{source} is current")
  else
    try io("#{crate}/src", Dir.mkdir("#{crate}/src"))
    try io(source, File.write_text(source, text))
    done = done.push("wrote #{source}")
  end

  built = try cargo(crate, extension)
  library = "#{root}#{plan.file}"
  if try copy(built, library)
    done = done.push("copied #{built} to #{library}")
  else
    done = done.push("#{library} is current")
  end

  # The manifest is read again: an edit made while cargo ran is kept, with the entry planned on it. When the edit names
  # another library file, replan refuses and the library just copied stays in native/; the error says to run build
  # again. An edit made between this read and the write below is still lost: that window is short, and File.replace
  # has no compare-and-swap to close it.
  now = try io(manifest, File.read_text(manifest))
  final = try Build.replan(manifest, toml, plan, now, name, os)
  key = "native.#{name}.#{os}"
  if final.manifest == now
    return ok(done.push("#{manifest} has #{key}"))
  end

  try io(manifest, File.replace(manifest, final.manifest.bytes))
  return ok(done.push("added #{key} to #{manifest}"))
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

# The root of the package of the file at `path`, ending in `/`: the nearest folder up from the file that has an
# `agentica.toml`.
def package_root(path: String) -> Result[String]
  file = try io(path, Path.resolve(path))
  folder = parent(file)
  while !folder.empty?
    if File.stat("#{folder}/agentica.toml").ok?
      return ok("#{folder}/")
    end

    folder = parent(folder)
  end

  return error("[NATIVE-GEN-IO] #{path}: no agentica.toml in its folder or above; build needs the package root")
end

# `path` without its last part and the separator before it ("" for a path of one part).
def parent(path: String) -> String
  length = path.length - last_part(path).length - 1
  if length <= 0
    return ""
  end

  return path.slice(0, length)
end

# The folder's `agentica.toml` without its `native` table, as a buffer: a library that is not built yet, or not for
# this system, then does not stop the check of the `.agc`. No buffer without a manifest, or for one that is not TOML,
# which the check reports.
def unbuilt(folder: String) -> Map[String, String]
  path = "#{folder}agentica.toml"
  buffers: Map[String, String] = {}
  kept = File.read_text(path).unwrap_or("")
  case Build.without_native(kept)
    ok(text) if File.stat(path).ok? -> return buffers.put(Path.resolve(path).unwrap_or(path), text)
    _ -> return buffers
  end
end

# The Rust file of `block` of the file at `path`, its trait named after `prefix` or the library.
def rust_of(block: Analysis.NativeBlock, prefix: String, path: String) -> Result[String]
  name = prefix
  if name.empty?
    name = default_prefix(block.library)
  end

  if !Names.c_identifier?(name)
    return error(
      "[NATIVE-GEN-PREFIX] the prefix #{name.inspect} is not an ASCII identifier; choose another with --prefix",
    )
  end

  return RustSide.render(block, RustSide.trait_name(name), last_part(path))
end

# Runs `cargo build --release` on the crate in the folder `crate` and gives the library it built, the file ending in
# `extension`, from the messages cargo writes on stdout. Its errors and progress go to stderr as cargo writes them.
# cargo runs in the current folder: `Process.spawn` takes no folder, and `spawn_captured`, which does, would hold
# back cargo's errors until it ends. So a `.cargo/config.toml` of `rust/` applies only when build runs from there.
def cargo(crate: String, extension: String) -> Result[String]
  args = [
    "build",
    "--release",
    "--lib",
    "--manifest-path",
    "#{crate}/Cargo.toml",
    "--message-format=json-render-diagnostics",
  ]

  started = Process.spawn("cargo", args)
  if !started.ok?
    return error("[NATIVE-GEN-CARGO] cannot run cargo: #{started.message}; build needs Rust's cargo on PATH")
  end

  process = started.unwrap!
  lines: List[String] = []
  line = Process.read_line(process, CARGO_MS)
  while line.ok?
    lines = lines.push(line.unwrap!)
    line = Process.read_line(process, CARGO_MS)
  end

  ended = Process.wait(process, CARGO_MS)
  Process.close(process)
  case ended
    ok(0) -> return Build.library_in(lines, extension)
    ok(code) -> return error("[NATIVE-GEN-CARGO] cargo build failed with exit code #{code}")
    error(message) -> return error("[NATIVE-GEN-CARGO] cargo build did not end: #{message}")
  end
end

# Copies the file `from` to `to`, unless `to` has its bytes already; true when it copied. A new `to` is written beside
# it and renamed into place. An existing one is replaced in one step with `File.replace`, so a program that loads it
# meanwhile sees the old library or the new one; a library over the 16 MiB of `File.replace` is removed and renamed
# into place instead, which leaves a moment with no file.
def copy(from: String, to: String) -> Result[Bool]
  hash = try io(from, File.sha256(from))
  kept = File.sha256(to)
  if kept.ok? and kept.unwrap! == hash
    return ok(false)
  end

  info = try io(from, File.stat(from))
  if File.stat(to).ok? and info.size_bytes <= REPLACE_MAX
    bytes = try read_all(from)
    try io(to, File.replace(to, bytes))
    return ok(true)
  end

  folder = to.slice(0, to.length - last_part(to).length)
  if !folder.empty?
    try io(folder, Dir.mkdir(folder))
  end

  part = "#{folder}.#{last_part(to)}.#{System.pid()}.part"
  written = copied(from, part)
  if written.ok? and File.stat(to).ok?
    written = io(to, Path.remove(to))
  end

  if written.ok?
    written = io(to, Path.rename(part, to))
  end

  if !written.ok?
    _ = Path.remove(part)
    return error(written.message)
  end

  return ok(true)
end

# The bytes of the file `from`, read 1 MiB at a time.
def read_all(from: String) -> Result[Bytes]
  input = try io(from, File.open(from))
  parts: List[Bytes] = []
  chunk = io(from, File.read_bytes(input, CHUNK))
  while chunk.ok? and !chunk.unwrap!.empty?
    parts = parts.push(chunk.unwrap!)
    chunk = io(from, File.read_bytes(input, CHUNK))
  end

  _ = File.close(input)
  try chunk
  return ok(Bytes.concat(parts))
end

# Writes the bytes of the file `from` to the new file `to`, 1 MiB at a time.
def copied(from: String, to: String) -> Result[Void]
  input = try io(from, File.open(from))
  output = try io(to, File.open(to, "write"))
  chunk = io(from, File.read_bytes(input, CHUNK))
  while chunk.ok? and chunk.unwrap!.size > 0
    written = io(to, File.write_bytes(output, chunk.unwrap!))
    if !written.ok?
      chunk = error(written.message)
    else
      chunk = io(from, File.read_bytes(input, CHUNK))
    end
  end

  _ = File.close(input)
  closed = io(to, File.close(output))
  try chunk
  return closed
end

# The header of the file at `path` as `files` has it: the disk, or a buffer in place of the file.
def header_in(files: Analysis.Workspace, path: String, prefix: String) -> Result[String]
  block = try block_in(files, path)
  names = try prefix_of(block, prefix)
  return CHeader.render(block, names, last_part(path))
end

# The one `extern module` block of the file at `path` as `files` has it.
def block_in(files: Analysis.Workspace, path: String) -> Result[Analysis.NativeBlock]
  case Analysis.native_modules(Analysis.open(files), path)
    ok(found) -> return one_block(found.blocks, path)
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

def one_block(blocks: List[Analysis.NativeBlock], path: String) -> Result[Analysis.NativeBlock]
  if blocks.size != 1
    return error("[NATIVE-GEN-BLOCK] #{path} has #{blocks.size} extern module blocks; native-gen makes a file for one")
  end

  return ok(blocks[0])
end

# The prefix `prefix` of the C names, or the default one of the block's library when it is empty.
def prefix_of(block: Analysis.NativeBlock, prefix: String) -> Result[CHeader.Prefix]
  name = prefix
  if name.empty?
    name = default_prefix(block.library)
  end

  case CHeader.prefix(name)
    ok(names) -> return ok(names)
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

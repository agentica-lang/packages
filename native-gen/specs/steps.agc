## The steps of `header.feature`. The command runs as a program under test; the steps here give a scenario a package
## cache of its own, so a native build never reuses or leaves an entry in the user's cache, a folder for the header
## that `--output` writes (both removed when the scenario ends), and the header of a fixture package, made before it is
## built, so only one golden header is committed.

import BDD from "std/bdd"
import NativeGen from "../native_gen"
import Build from "../src/build"
import Scaffold from "../src/scaffold"

# The name in the context of the header file that `--output` writes.
WRITTEN = "written"
# The name in the context of the folder that `native new` wrote a module in.
SCAFFOLD = "scaffold"

# A fresh folder and the context that removes it at the end of the scenario.
struct Made
  ctx: BDD.Context
  path: String
end

def main() -> Void
  BDD.run([
    BDD.step("a fresh package cache", &fresh_cache),
    BDD.step("the header goes to a fresh folder as {string}", &fresh_output),
    BDD.step("the written header includes:", &written_header),
    BDD.step("the header of the package of {string}", &package_header),
    BDD.step("a fresh folder", &folder_step),
    BDD.step("the agentica.toml of the fresh folder is:", &manifest_step),
    BDD.step("the agentica.toml of the fresh folder has the line {string}", &manifest_line),
    BDD.step("native new {string} in the fresh folder", &new_module),
    BDD.step("native new --lang rust {string} in the fresh folder", &new_rust_module),
    BDD.step("native new --lang rust {string} writes the files of {string}", &same_crate_files),
    BDD.step("the agentica.toml of the fresh folder is still {string}", &manifest_is),
    BDD.step("the agentica.toml of the fresh folder starts with:", &manifest_start),
    BDD.step("the fresh folder has no {string}", &missing),
    BDD.step("the agentica.toml of the fresh folder still has only the line {string}", &manifest_kept),
    BDD.step("the header of {string} in the fresh folder passes --check", &header_kept),
    BDD.step("the program argument {string} in the fresh folder", &argument_in_folder),
    BDD.step("the Agentica program {string} in the fresh folder", &program_in_folder),
    BDD.step("the C compiler builds as {string}", &compiler),
    BDD.step("the file {string} in the fresh folder is:", &file_in_folder),
    BDD.step("the library of {string} on {string} is {string}", &library_file),
    BDD.step("a fresh package with the Rust module in {string}", &rust_package),
    BDD.step("a program in the fresh folder that runs build of {string} there", &build_runner),
    BDD.step("the program argument {string} in the fresh folder, relative to the current folder", &relative_argument),
    BDD.step("a fake cargo on PATH that exits with {int} and prints:", &fake_cargo),
    BDD.step("the file {string} in the fresh folder is removed", &removed),
    BDD.step("the fresh folder has {string}", &present),
    BDD.step("the fresh folder has the library of {string}", &library_present),
    BDD.step("the agentica.toml of the fresh folder has the entry of {string}", &entry_present),
    BDD.step("the agentica.toml of the fresh folder is {string}", &manifest_text),
    BDD.step("the agentica.toml of the fresh folder is {string} with CRLF lines", &manifest_crlf),
    BDD.step("the entry of {string} on {string} cannot be added: {string}", &entry_refused),
    BDD.step(
      "the entry of {string} on {string} added to the agentica.toml of the fresh folder has only CRLF lines",
      &entry_crlf,
    ),
    BDD.step(
      "the entry of {string} on {string}, planned before agentica.toml became {string}, gives {string}",
      &replanned,
    ),
    BDD.step("the entry of {string} on {string} added to the agentica.toml of the fresh folder gives:", &entry_added),
  ])
end

# Writes `native/NAME_native.h` beside the package file `FOLDER/NAME.agc`, removed when the scenario ends (git ignores
# it too). A step runs in the folder that `agentica test` ran in, the package or specs/, while the paths of the feature
# are from specs/.
def package_header(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = args[0]
  if File.stat("specs/header.feature").ok?
    path = "specs/#{path}"
  end

  parts = path.split("/")
  file = parts[parts.size - 1]
  name = file.slice(0, file.length - ".agc".length)
  folder = parts.take(parts.size - 1).join("/")
  made = NativeGen.header(path)
  if !made.ok?
    return BDD.assert(ctx, false, made.message)
  end

  header = "#{folder}/native/#{name}_native.h"
  kept = BDD.after(ctx) do |_done| Path.remove(header) end
  written = File.write_text(header, made.unwrap!)
  return BDD.assert(kept, written.ok?, "cannot write the header of #{path}: #{written.message}")
end

# A fresh folder that the scenario keeps, for `native new`.
def folder_step(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case fresh_folder(ctx)
    ok(made) -> return BDD.set(made.ctx, SCAFFOLD, JSON.from(made.path))
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# The doc string as the agentica.toml of the fresh folder, as it is (no newline added at its end).
def manifest_step(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return file_written(ctx, BDD.doc_string(ctx))
end

def manifest_line(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return file_written(ctx, line_manifest(args[0]))
end

def manifest_kept(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = File.read_text(in_folder(ctx, "agentica.toml")).unwrap_or("")
  return BDD.assert(ctx, text == line_manifest(args[0]), "agentica.toml changed: #{text}")
end

# The agentica.toml of a package named pkg with `line` after its name.
def line_manifest(line: String) -> String
  return "name = \"pkg\"\n#{line}\n"
end

# What `--check` does for `NAME.agc` of the fresh folder and `native/NAME_native.h`: the header made from the file on
# disk is the one written.
def header_kept(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = args[0]
  name = file.slice(0, file.length - ".agc".length)
  made = NativeGen.header(in_folder(ctx, file))
  written = File.read_text(in_folder(ctx, "native/#{name}_native.h"))
  return BDD.assert(ctx, made.ok? and written.ok? and made.unwrap! == written.unwrap!, "the header is stale")
end

def file_written(ctx: BDD.Context, text: String) -> BDD.Context
  done = File.write_text(in_folder(ctx, "agentica.toml"), text)
  return BDD.assert(ctx, done.ok?, "cannot write agentica.toml: #{done.message}")
end

# `NativeGen.scaffold` of the module `args[0]` in the fresh folder.
def new_module(ctx: BDD.Context, args: List[String]) -> BDD.Context
  done = NativeGen.scaffold(in_folder(ctx, args[0]))
  return BDD.assert(ctx, done.ok?, "native new #{args[0]} failed: #{done.message}")
end

def new_rust_module(ctx: BDD.Context, args: List[String]) -> BDD.Context
  done = NativeGen.scaffold(in_folder(ctx, args[0]), "rust")
  return BDD.assert(ctx, done.ok?, "native new --lang rust #{args[0]} failed: #{done.message}")
end

# The Cargo.toml and .gitignore that `new --lang rust` writes for `args[0]` are the ones of the example `args[1]`, so
# the two keep one shape.
def same_crate_files(ctx: BDD.Context, args: List[String]) -> BDD.Context
  folder = args[1]
  if File.stat("specs/header.feature").ok?
    folder = "specs/#{folder}"
  end

  cargo = File.read_text("#{folder}/rust/Cargo.toml").unwrap_or("")
  ignore = File.read_text("#{folder}/rust/.gitignore").unwrap_or("")
  kept = BDD.assert(
    ctx,
    cargo == Scaffold.cargo_toml(args[0]),
    "rust/Cargo.toml differs: #{Scaffold.cargo_toml(args[0])}",
  )

  return BDD.assert(kept, ignore == Scaffold.gitignore(), "rust/.gitignore differs")
end

# The agentica.toml of the fresh folder is `args[0]`, with `'` for `"`, and a newline.
def manifest_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  text = File.read_text(in_folder(ctx, "agentica.toml")).unwrap_or("")
  return BDD.assert(ctx, text == "#{args[0].replace("'", "\"")}\n", "agentica.toml is: #{text}")
end

def manifest_start(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case File.read_text(in_folder(ctx, "agentica.toml"))
    ok(text) -> return BDD.assert(ctx, text.start_with?(BDD.doc_string(ctx)), "agentica.toml changed: #{text}")
    error(message) -> return BDD.assert(ctx, false, "cannot read agentica.toml: #{message}")
  end
end

def missing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, !File.stat(in_folder(ctx, args[0])).ok?, "#{args[0]} was written")
end

# CC for "C11", or for "C++" fixtures/cxx.sh by its absolute path, since a program outside the fixtures runs in its
# own folder.
def compiler(ctx: BDD.Context, args: List[String]) -> BDD.Context
  if args[0] == "C11"
    return BDD.given_env(ctx, "CC", "cc -std=c11 -Wall -Wextra -Werror")
  end

  script = "fixtures/cxx.sh"
  if File.stat("specs/header.feature").ok?
    script = "specs/#{script}"
  end

  return BDD.given_env(ctx, "CC", "sh #{Path.resolve(script).unwrap!}")
end

# The doc string as the file `args[0]` of the fresh folder, in a folder made for it.
def file_in_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  done = written_in(ctx, args[0], "#{BDD.doc_string(ctx)}\n")
  return BDD.assert(ctx, done.ok?, "cannot write #{args[0]}: #{done.message}")
end

# Writes `text` as the file `name` of the fresh folder, in a folder made for it.
def written_in(ctx: BDD.Context, name: String, text: String) -> Result[Void]
  path = in_folder(ctx, name)
  parts = path.split("/")
  try Dir.mkdir(parts.take(parts.size - 1).join("/"))
  return File.write_text(path, text)
end

# The library of `args[0]` on `args[1]`, or the code in brackets that starts its error.
def library_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case Build.library_file(args[0], args[1])
    ok(file) -> return BDD.assert(ctx, file == args[2], "the library is #{file}")
    error(message) -> return BDD.assert(ctx, message.start_with?(args[2]), message)
  end
end

# A fresh folder with a package of one Rust module, demo: its `.agc` at `args[0]`, and at the root `agentica.toml`
# with only a name and `rust/Cargo.toml`.
def rust_package(ctx: BDD.Context, args: List[String]) -> BDD.Context
  kept = folder_step(ctx, [])
  block = "extern module \"demo\"\n  def add(a: Int, b: Int) -> Int\nend\n"
  files = {args[0]: block, "agentica.toml": line_manifest(""), "rust/Cargo.toml": "[package]\nname = \"demo\"\n"}
  for name in files.keys
    done = written_in(kept, name, files.get(name, ""))
    if !done.ok?
      return BDD.assert(kept, false, done.message)
    end
  end

  return kept
end

# A `cargo` in the folder bin/ of the fresh folder, the only folder of the program's PATH, that prints the doc string
# and exits with `args[0]`. FOLDER in it is the fresh folder and EXT the ending of a library on this system; the
# files libdemoEXT and libtwoEXT are made there.
def fake_cargo(ctx: BDD.Context, args: List[String]) -> BDD.Context
  folder = "#{fresh_path(ctx)}/"
  ext = Build.extension(System.os()).unwrap_or(".so")
  text = BDD.doc_string(ctx).replace("FOLDER", folder.slice(0, folder.length - 1)).replace("EXT", ext)
  lines = text.split("\n").map do |line: String| "printf '%s\\n' '#{line}'" end
  script = "#!/bin/sh\n#{lines.join("\n")}\nexit #{args[0]}\n"
  made = [
    written_in(ctx, "bin/cargo", script),
    written_in(ctx, "libdemo#{ext}", "demo"),
    written_in(ctx, "target/libdemo#{ext}", "demo"),
    written_in(ctx, "libtwo#{ext}", "two"),
  ]

  if !made.all? do |done: Result[Void]| done.ok? end
    return BDD.assert(ctx, false, "cannot write the fake cargo")
  end

  chmod = Process.spawn("chmod", ["+x", in_folder(ctx, "bin/cargo")])
  if !chmod.ok? or Process.wait(chmod.unwrap!, 10_000) != ok(0)
    return BDD.assert(ctx, false, "cannot make the fake cargo executable")
  end

  return BDD.given_env(ctx, "PATH", in_folder(ctx, "bin"))
end

# A program `run.agc` in the fresh folder that runs `agentica cli.agc build args[0]` in that folder (a program under
# test runs in the folder of the feature, and `spawn_captured` gives the build its own), then prints what build
# printed and exits with its code. So build runs in the package, as a user runs it.
def build_runner(ctx: BDD.Context, args: List[String]) -> BDD.Context
  cli = "../cli.agc"
  if File.stat("specs/header.feature").ok?
    cli = "cli.agc"
  end

  found = Process.spawn_captured("sh", ["-c", "command -v agentica"])
  if !found.ok?
    return BDD.assert(ctx, false, "cannot look for agentica: #{found.message}")
  end

  binary = ""
  case Process.output(found.unwrap!, 10_000)
    ok(out) -> binary = out.stdout.trim
    error(_) -> binary = ""
  end

  Process.close(found.unwrap!)
  command = "[#{Path.resolve(cli).unwrap!.inspect}, \"build\", #{args[0].inspect}]"
  program = [
    "def main() -> Void",
    "  p = Process.spawn_captured(#{binary.inspect}, #{command}, #{fresh_path(ctx).inspect}).unwrap!",
    "  out = Process.output(p, 60_000).unwrap!",
    "  print(out.stdout)",
    "  IO.warn(out.stderr)",
    "  System.exit(Process.wait(p, 60_000).unwrap!)",
    "end",
    "",
  ].join("\n")

  done = written_in(ctx, "run.agc", program)
  if !done.ok? or binary.empty?
    return BDD.assert(ctx, false, "cannot write run.agc (agentica is #{binary.inspect})")
  end

  return BDD.given_program(ctx, in_folder(ctx, "run.agc"))
end

def removed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  done = Path.remove(in_folder(ctx, args[0]))
  return BDD.assert(ctx, done.ok?, "cannot remove #{args[0]}: #{done.message}")
end

def present(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.assert(ctx, File.stat(in_folder(ctx, args[0])).ok?, "#{args[0]} was not written")
end

def library_present(ctx: BDD.Context, args: List[String]) -> BDD.Context
  file = Build.library_file(args[0], System.os()).unwrap_or("")
  return BDD.assert(ctx, File.stat(in_folder(ctx, file)).ok?, "#{file} was not written")
end

# The entry of `args[0]` for this system names the library file of `args[0]`.
def entry_present(ctx: BDD.Context, args: List[String]) -> BDD.Context
  os = System.os()
  text = File.read_text(in_folder(ctx, "agentica.toml")).unwrap_or("")
  file = Build.library_file(args[0], os).unwrap_or("")
  return BDD.assert(ctx, text.include?("#{os} = { file = #{file.inspect} }"), "agentica.toml is: #{text}")
end

# The agentica.toml of the fresh folder: `args[0]`, whose `\n` the table cell made line ends.
def manifest_text(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return file_written(ctx, args[0])
end

def manifest_crlf(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return file_written(ctx, "#{args[0].replace("\n", "\r\n")}\r\n")
end

def entry_refused(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case planned(ctx, args[0], args[1])
    ok(plan) -> return BDD.assert(ctx, false, "agentica.toml is: #{plan.manifest}")
    error(message) -> return BDD.assert(ctx, message.start_with?(args[2]), message)
  end
end

# Every line of the text that build writes ends with CRLF, the lines it added too.
def entry_crlf(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case planned(ctx, args[0], args[1])
    ok(plan) ->
      lines = plan.manifest.split("\n")
      crlf = lines.take(lines.size - 1).all? do |line: String| line.end_with?("\r") end
      return BDD.assert(ctx, crlf and plan.manifest.include?("linux = "), "agentica.toml is: #{plan.manifest.inspect}")
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# The plan made on the agentica.toml of the fresh folder, then made again on `args[2]`: its
# manifest has the entry added, or is `args[2]` kept, or the code in brackets that starts its error.
def replanned(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = in_folder(ctx, "agentica.toml")
  before = File.read_text(path).unwrap_or("")
  now = args[2]
  case Build.plan(path, before, args[0], args[1])
    ok(plan) -> return replan_matches(ctx, Build.replan(path, before, plan, now, args[0], args[1]), now, args[3])
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

def replan_matches(ctx: BDD.Context, again: Result[Build.Plan], now: String, want: String) -> BDD.Context
  case again
    ok(plan) if want == "kept" -> return BDD.assert(ctx, plan.manifest == now, plan.manifest)
    ok(plan) if want == "added" ->
      return BDD.assert(ctx, plan.manifest.start_with?(now) and plan.manifest.include?("linux = "), plan.manifest)
    ok(plan) -> return BDD.assert(ctx, false, "agentica.toml is: #{plan.manifest}")
    error(message) -> return BDD.assert(ctx, message.start_with?(want), message)
  end
end

def planned(ctx: BDD.Context, name: String, os: String) -> Result[Build.Plan]
  path = in_folder(ctx, "agentica.toml")
  return Build.plan(path, File.read_text(path).unwrap_or(""), name, os)
end

# The text that build writes to the agentica.toml of the fresh folder for the module `args[0]` on the system `args[1]`.
def entry_added(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = in_folder(ctx, "agentica.toml")
  case Build.plan(path, File.read_text(path).unwrap_or(""), args[0], args[1])
    ok(plan) -> return BDD.assert(ctx, plan.manifest == BDD.doc_string(ctx), "agentica.toml is: #{plan.manifest}")
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# The path of `args[0]` in the fresh folder, written from the folder the program runs in (specs/, where a step may
# run in the package): one `..` per part of that folder, then the absolute path without its leading `/` (Unix only).
def relative_argument(ctx: BDD.Context, args: List[String]) -> BDD.Context
  current = Path.cwd().unwrap!
  if File.stat("specs/header.feature").ok?
    current = "#{current}/specs"
  end

  up = current.split("/").select do |part: String| !part.empty? end.map do |_part: String| ".." end
  path = in_folder(ctx, args[0])
  return BDD.given_argument(ctx, "#{up.join("/")}#{path}")
end

def argument_in_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_argument(ctx, in_folder(ctx, args[0]))
end

def program_in_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_program(ctx, in_folder(ctx, args[0]))
end

# The path of `name` in the folder of `new_module`.
def in_folder(ctx: BDD.Context, name: String) -> String
  return Path.join([fresh_path(ctx), name]).unwrap!
end

def fresh_cache(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case fresh_folder(ctx)
    ok(made) -> return BDD.given_env(made.ctx, "XDG_CACHE_HOME", made.path)
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

# `--output` to the file `args[0]` in a fresh folder, whose path the scenario keeps.
def fresh_output(ctx: BDD.Context, args: List[String]) -> BDD.Context
  case fresh_folder(ctx)
    ok(made) ->
      path = Path.join([made.path, args[0]]).unwrap!
      kept = BDD.set(made.ctx, WRITTEN, JSON.from(path))
      return BDD.given_argument(BDD.given_argument(kept, "--output"), path)
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

def written_header(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  path = JSON.string(BDD.get(ctx, WRITTEN).unwrap!).unwrap!
  case File.read_text(path)
    ok(text) -> return BDD.assert(ctx, text.include?(BDD.doc_string(ctx)), "#{path} is not the header: #{text}")
    error(message) -> return BDD.assert(ctx, false, "cannot read #{path}: #{message}")
  end
end

# A new private folder, removed when the scenario ends, with the context that holds its removal.
def fresh_folder(ctx: BDD.Context) -> Result[Made]
  base = System.env("TMPDIR").unwrap_or("/tmp")
  if base.empty?
    base = "/tmp"
  end

  folder = try Path.join([base, "native-gen-#{System.pid()}-#{Random.int(0, 1_000_000_000)}"])
  made = Dir.mkdir_private(folder)
  if !made.ok?
    return error("cannot make #{folder}: #{made.message}")
  end

  return ok(Made(ctx: BDD.after(ctx) do |_done| Path.remove(folder) end, path: folder))
end

# The path of the fresh folder of `folder_step`.
def fresh_path(ctx: BDD.Context) -> String
  return JSON.string(BDD.get(ctx, SCAFFOLD).unwrap!).unwrap!
end

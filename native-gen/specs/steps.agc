## The steps of `header.feature`. The command runs as a program under test; the steps here give a scenario a package
## cache of its own, so a native build never reuses or leaves an entry in the user's cache, a folder for the header
## that `--output` writes (both removed when the scenario ends), and the header of a fixture package, made before it is
## built, so only one golden header is committed.

import BDD from "std/bdd"
import NativeGen from "../native_gen"
import Build from "../src/build"

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
    BDD.step("the agentica.toml of the fresh folder starts with:", &manifest_start),
    BDD.step("the fresh folder has no {string}", &missing),
    BDD.step("the agentica.toml of the fresh folder still has only the line {string}", &manifest_kept),
    BDD.step("the header of {string} in the fresh folder passes --check", &header_kept),
    BDD.step("the program argument {string} in the fresh folder", &argument_in_folder),
    BDD.step("the Agentica program {string} in the fresh folder", &program_in_folder),
    BDD.step("the C compiler builds as {string}", &compiler),
    BDD.step("the file {string} in the fresh folder is:", &file_in_folder),
    BDD.step("the library of {string} on {string} is {string}", &library_file),
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
  path = in_folder(ctx, args[0])
  parts = path.split("/")
  made = Dir.mkdir(parts.take(parts.size - 1).join("/"))
  done = File.write_text(path, "#{BDD.doc_string(ctx)}\n")
  return BDD.assert(ctx, made.ok? and done.ok?, "cannot write #{path}: #{done.message}")
end

def library_file(ctx: BDD.Context, args: List[String]) -> BDD.Context
  made = Build.library_file(args[0], args[1])
  return BDD.assert(ctx, made.ok? and made.unwrap! == args[2], "the library is #{made}")
end

# The text that build writes to the agentica.toml of the fresh folder for the module `args[0]` on the system `args[1]`.
def entry_added(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = in_folder(ctx, "agentica.toml")
  case Build.plan(path, File.read_text(path).unwrap_or(""), args[0], args[1])
    ok(plan) -> return BDD.assert(ctx, plan.manifest == BDD.doc_string(ctx), "agentica.toml is: #{plan.manifest}")
    error(message) -> return BDD.assert(ctx, false, message)
  end
end

def argument_in_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_argument(ctx, in_folder(ctx, args[0]))
end

def program_in_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.given_program(ctx, in_folder(ctx, args[0]))
end

# The path of `name` in the folder of `new_module`.
def in_folder(ctx: BDD.Context, name: String) -> String
  folder = JSON.string(BDD.get(ctx, SCAFFOLD).unwrap!).unwrap!
  return Path.join([folder, name]).unwrap!
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

## `build`: the project and the `agentica` binary become a release folder.

import Config from "config"
import Errors from "errors"
import Files from "files"
import Layout from "layout"
import Natives from "natives"
import Shell from "shell"
import Toml from "std/toml"

## What `build` is told. An empty `agentica` is the one on PATH; an empty `entry` is the one of `[tool.release]`.
struct Options
  project: String = "."
  out: String = "_release"
  agentica: String = ""
  entry: String = ""
end

## The folder written, its manifest, and the native libraries that the target must have by name.
struct Built
  path: String
  manifest: Layout.Manifest
  system_libraries: List[String]
end

## Everything is checked before a file is written, and the folder is made as `NAME-VERSION.partial` and renamed when
## it is whole, so a failed build leaves no release folder.
def build(options: Options) -> Result[Built]
  return Errors.invalid("a release has an sh launcher, which Windows does not run yet") if System.os() == "windows"

  project = try Path.real(options.project)
  text = try File.read_text(Layout.at(project, "agentica.toml"))
  config = try Config.parse(text, options.entry)
  libraries = config.system_libraries + try dependency_libraries(project)
  try Files.program(project, config.entry)
  for path in config.include
    try Files.confined(project, path)
  end

  binary = try located(options.agentica)
  running = (try Shell.run(binary, ["--version"], ".")).strip
  out = try Path.resolve(options.out)
  root = Layout.at(out, Layout.folder(config.name, config.version))
  partial = "#{root}.partial"
  for path in [root, partial]
    return Errors.invalid("#{path} exists already; remove it or choose another --out") if File.lstat(path).ok?
  end

  try Shell.run("mkdir", ["-p", partial], ".")
  assembled = assemble(project, partial, config, binary, running)
  case assembled
    error(e) ->
      _ = Path.remove(partial)
      return error(e.message, kind: e.kind)
    ok(_) -> nil
  end

  renamed = Path.rename(partial, root)
  if !renamed.ok?
    _ = Path.remove(partial)
    return Errors.failed("cannot rename #{partial} to #{root}: #{renamed.message}")
  end

  ok(Built(path: root, manifest: assembled.unwrap!, system_libraries: libraries.sort))
end

private

def located(given: String) -> Result[String]
  return Shell.find_agentica() if given.empty?

  Path.resolve(given)
end

# The natives of the packages in deps/: the ones of the lock must be there, and every manifest there is checked.
def dependency_libraries(project: String) -> Result[List[String]]
  deps = Layout.at(project, "deps")
  wanted = try locked(project)
  present: List[String] = []
  if File.lstat(deps).ok?
    present = try Dir.list(deps)
  end

  for name in wanted
    if !present.include?(name)
      return Errors.invalid("deps/#{name} is missing; run `agentica install` so its native modules can be checked")
    end
  end

  libraries: List[String] = []
  for name in present
    manifest = Layout.at(deps, "#{name}/agentica.toml")
    if File.stat(manifest).ok?
      doc = Toml.parse(try File.read_text(manifest))
      return Errors.invalid("deps/#{name}/agentica.toml: #{doc.message}") if !doc.ok?

      libraries = libraries + try Natives.libraries(doc.unwrap!, "deps/#{name}/agentica.toml")
    end
  end

  ok(libraries)
end

def locked(project: String) -> Result[List[String]]
  path = Layout.at(project, "agentica.lock")
  return ok([]) if !File.lstat(path).ok?

  doc = Toml.parse(try File.read_text(path))
  return Errors.invalid("agentica.lock: #{doc.message}") if !doc.ok?

  names: List[String] = []
  case Toml.get(doc.unwrap!, "package")
    ok(Toml.Value.Array(items)) ->
      for item in items
        case item
          Toml.Value.Table(fields) ->
            case fields.get("name")
              some(Toml.Value.Str(name)) -> names = names.push(name)
              _ -> return Errors.invalid("agentica.lock has a package with no name")
            end

          _ -> return Errors.invalid("agentica.lock has a package that is not a table")
        end
      end

    _ -> nil
  end

  ok(names)
end

def assemble(
  project: String,
  root: String,
  config: Config.Config,
  binary: String,
  running: String,
) -> Result[Layout.Manifest]
  try Shell.run(
    "mkdir",
    ["-p", Layout.at(root, "bin"), Layout.at(root, "erts"), Layout.at(root, "lib"), Layout.at(root, "releases")],
    ".",
  )

  try Shell.run(binary, ["compile", config.entry, "-o", Layout.at(root, Layout.program_path(config.name))], project)

  try Shell.run("cp", [binary, Layout.at(root, Layout.binary_path())], ".")
  launcher = Layout.launcher_path(config.name)
  try File.write_text(Layout.at(root, launcher), Layout.launcher(config.name))
  try Shell.run("chmod", ["755", Layout.at(root, launcher)], ".")
  for path in config.include
    try included(project, root, path)
  end

  paths = try Files.walk(root)
  manifest = Layout.Manifest(
    name: config.name,
    version: config.version,
    agentica: running,
    os: System.os(),
    arch: (try Shell.run("uname", ["-m"], ".")).strip,
    files: try Files.hashed(root, paths),
  )

  try File.write_text(Layout.at(root, Layout.MANIFEST), JSON.encode(manifest) + "\n")
  ok(manifest)
end

# `cp -RP` copies a link inside a folder as a link, which `Files.walk` then refuses.
def included(project: String, root: String, path: String) -> Result[Void]
  parts = path.split("/")
  if parts.size > 1
    _ = try Shell.run("mkdir", ["-p", Layout.at(root, parts.take(parts.size - 1).join("/"))], ".")
  end

  _ = try Shell.run("cp", ["-RP", Layout.at(project, path), Layout.at(root, path)], ".")
  ok()
end

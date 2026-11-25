## `build`: the project and the `agentica` binary become a release folder.

import Config from "config"
import Errors from "errors"
import Files from "files"
import Layout from "layout"
import Names from "names"
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
  os = System.os()
  config = try Config.parse(text, options.entry, os)
  libraries = config.system_libraries + try dependency_libraries(project, os)
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

  _ = try Shell.run("mkdir", ["-p", out], ".")
  _ = try Shell.run("mkdir", [partial], ".")
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

  ok(Built(path: root, manifest: assembled.unwrap!, system_libraries: libraries.uniq.sort))
end

private

# One package of `agentica.lock`: where its `agentica.toml` is depends on how it is locked.
struct Locked
  name: String
  path: String
  workspace: Bool
  subdir: String
end

def located(given: String) -> Result[String]
  return Shell.find_agentica() if given.empty?

  Path.resolve(given)
end

# The natives of the locked packages (the ones of `deps/` and the folders that the lock names), read from each
# `agentica.toml`. A `deps/` folder that the lock does not name is not read.
def dependency_libraries(project: String, os: String) -> Result[List[String]]
  libraries: List[String] = []
  for locked in try locks(project)
    folder = try manifest_folder(project, locked)
    if folder.some?
      path = Layout.at(folder.unwrap!, "agentica.toml")
      owner = "dependency #{locked.name} (#{path})"
      text = File.read_text(path)
      return Errors.invalid("#{owner} is missing; run `agentica install`") if !text.ok?

      doc = Toml.parse(text.unwrap!)
      return Errors.invalid("#{owner}: #{doc.message}") if !doc.ok?

      libraries = libraries + try Natives.libraries(doc.unwrap!, owner, os)
    end
  end

  ok(libraries)
end

# The folder of the package, or none when it has no folder of its own: a `path` package is in its folder; a member
# of the workspace of the project is in the workspace; the workspace itself has no folder (its members have); the
# others are in `deps/NAME`.
def manifest_folder(project: String, locked: Locked) -> Result[Optional[String]]
  try Names.inside("lock name", locked.name)
  if !locked.path.empty?
    return ok(some(Layout.at(project, locked.path))) if !locked.path.start_with?("/")

    return ok(some(locked.path))
  end

  if locked.workspace
    return ok(none) if locked.subdir.empty?

    try Names.inside("lock subdir", locked.subdir)
    root = workspace_root(project)
    return Errors.invalid("#{locked.name} is a workspace member but no workspace is above the project") if !root.some?

    return ok(some(Layout.at(root.unwrap!, locked.subdir)))
  end

  ok(some(Layout.at(Layout.at(project, "deps"), locked.name)))
end

# The nearest folder above the project (or the project) whose `agentica.toml` has a `[workspace]` table.
def workspace_root(dir: String) -> Optional[String]
  text = File.read_text(Layout.at(dir, "agentica.toml"))
  if text.ok?
    doc = Toml.parse(text.unwrap!)
    return some(dir) if doc.ok? and Toml.get(doc.unwrap!, "workspace").ok?
  end

  return none if dir == "/"

  parts = dir.split("/")
  parent = parts.take(parts.size - 1).join("/")
  if parent.empty?
    parent = "/"
  end

  workspace_root(parent)
end

def locks(project: String) -> Result[List[Locked]]
  path = Layout.at(project, "agentica.lock")
  return ok([]) if !File.lstat(path).ok?

  doc = Toml.parse(try File.read_text(path))
  return Errors.invalid("agentica.lock: #{doc.message}") if !doc.ok?

  found: List[Locked] = []
  case Toml.get(doc.unwrap!, "package")
    ok(Toml.Value.Array(items)) ->
      for item in items
        case item
          Toml.Value.Table(fields) ->
            name = text_of(fields.get("name"))
            return Errors.invalid("agentica.lock has a package with no name") if name.empty?

            workspace = false
            case fields.get("workspace")
              some(Toml.Value.Bool(flag)) -> workspace = flag
              _ -> nil
            end

            found = found.push(
              Locked(
                name: name,
                path: text_of(fields.get("path")),
                workspace: workspace,
                subdir: text_of(fields.get("subdir")),
              ),
            )
          _ -> return Errors.invalid("agentica.lock has a package that is not a table")
        end
      end

    _ -> nil
  end

  ok(found)
end

def text_of(value: Optional[Toml.Value]) -> String
  case value
    some(Toml.Value.Str(text)) -> text
    _ -> ""
  end
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
    ["-p", Layout.at(root, "bin"), Layout.at(root, "runtime"), Layout.at(root, "lib"), Layout.at(root, "releases")],
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

## `build`: the project and the `agentica` binary become a release folder.

import Config from "config"
import Errors from "errors"
import Files from "files"
import Layout from "layout"
import Shell from "shell"

## What `build` is told. An empty `agentica` is the one on PATH; an empty `version` or `entry` is the one of
## `[tool.release]`.
struct Options
  project: String = "."
  out: String = "_release"
  agentica: String = ""
  version: String = ""
  entry: String = ""
end

## The folder written, its manifest, and the native libraries that the target must have by name.
struct Built
  path: String
  manifest: Layout.Manifest
  system_libraries: List[String]
end

def build(options: Options) -> Result[Built]
  project = try Path.resolve(options.project)
  text = try File.read_text(Layout.at(project, "agentica.toml"))
  config = try Config.parse(text, options.version, options.entry)
  return Errors.invalid("a release has an sh launcher, which Windows does not run yet") if System.os() == "windows"

  binary = try located(options.agentica)
  version = try Shell.run(binary, ["--version"], ".")
  running = version.strip
  if !config.agentica.empty? and config.agentica != running
    return Errors.invalid("the project asks for agentica #{config.agentica}, #{binary} is #{running}")
  end

  out = try Path.resolve(options.out)
  root = Layout.at(out, Layout.folder(config.name, config.version))
  return Errors.invalid("#{root} exists already; remove it or choose another --out") if File.stat(root).ok?

  try Shell.run(
    "mkdir",
    ["-p", Layout.at(root, "bin"), Layout.at(root, "erts"), Layout.at(root, "lib"), Layout.at(root, "releases")],
    ".",
  )

  try Shell.run(binary, ["compile", config.entry, "-o", Layout.at(root, Layout.program_path(config.name))], project)

  try put(binary, root, Layout.binary_path())
  launcher = Layout.launcher_path(config.name)
  try File.write_text(Layout.at(root, launcher), Layout.launcher(config.name))
  try Shell.run("chmod", ["755", Layout.at(root, launcher)], ".")
  for path in config.include
    try included(project, root, path)
  end

  paths = try Files.walk(root)
  entries = try Files.hashed(root, paths)
  manifest = Layout.Manifest(
    name: config.name,
    version: config.version,
    agentica: running,
    os: System.os(),
    arch: (try Shell.run("uname", ["-m"], ".")).strip,
    files: entries,
  )

  try File.write_text(Layout.at(root, Layout.MANIFEST), JSON.encode(manifest) + "\n")
  ok(Built(path: root, manifest: manifest, system_libraries: config.system_libraries))
end

private

def located(given: String) -> Result[String]
  return Shell.find_agentica() if given.empty?

  Path.resolve(given)
end

# A copy of `source` at `path` in the release, with the permissions of the original.
def put(source: String, root: String, path: String) -> Result[Void]
  _ = try Shell.run("cp", [source, Layout.at(root, path)], ".")
  ok()
end

def included(project: String, root: String, path: String) -> Result[Void]
  from = Layout.at(project, path)
  return Errors.invalid("include #{path.inspect} is not in the project") if !File.stat(from).ok?

  to = Layout.at(root, path)
  parts = path.split("/")
  if parts.size > 1
    _ = try Shell.run("mkdir", ["-p", Layout.at(root, parts.take(parts.size - 1).join("/"))], ".")
  end

  _ = try Shell.run("cp", ["-R", from, to], ".")
  ok()
end

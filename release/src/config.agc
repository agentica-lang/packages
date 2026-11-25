## What a release needs from the `agentica.toml` of the project: the name, the version and `[tool.release]`. It reads
## text and does no I/O.

import Errors from "errors"
import Toml from "std/toml"

## `name` and `version` make the folder `NAME-VERSION`; `entry` is the program; `include` are files or folders of the
## project copied into the release; `agentica` is a version the binary must have (empty: any); `system_libraries` are
## the native libraries found by name on the target.
struct Config
  name: String
  version: String
  entry: String
  include: List[String]
  agentica: String
  system_libraries: List[String]
end

## The config of the manifest text. `version` (from the command line) wins over `[tool.release]`, and `entry` over
## its `entry`, when they are not empty.
def parse(text: String, version: String, entry: String) -> Result[Config]
  parsed = Toml.parse(text)
  return Errors.invalid("agentica.toml: #{parsed.message}") if !parsed.ok?

  doc = parsed.unwrap!
  name = text_at(doc, "tool.release.name").unwrap_or(text_at(doc, "name").unwrap_or(""))
  try word("name", name, "set name in agentica.toml")
  chosen = version
  if chosen.empty?
    chosen = text_at(doc, "tool.release.version").unwrap_or("")
  end

  try word("version", chosen, "set version in [tool.release] of agentica.toml, or pass --version")
  program = entry
  if program.empty?
    program = text_at(doc, "tool.release.entry").unwrap_or("main.agc")
  end

  try inside("entry", program)
  return Errors.invalid("entry #{program.inspect} is not an .agc file") if !program.end_with?(".agc")

  include = try paths_at(doc)
  libraries = try natives(doc)
  ok(
    Config(
      name: name,
      version: chosen,
      entry: program,
      include: include,
      agentica: text_at(doc, "tool.release.agentica").unwrap_or(""),
      system_libraries: libraries,
    ),
  )
end

private

PLATFORMS = ["linux", "macos", "windows"]

def text_at(doc: Toml.Value, path: String) -> Optional[String]
  case Toml.get(doc, path)
    ok(Toml.Value.Str(text)) -> some(text)
    _ -> none
  end
end

# A name or a version goes into a folder name and a script: letters, digits, `.`, `_` and `-`, not starting with `.`
# or `-`.
def word(label: String, text: String, help: String) -> Result[Void]
  return Errors.invalid("#{label} is empty: #{help}") if text.empty?

  allowed = text.bytes.to_a.all? { |byte| plain_byte?(byte) }
  if !allowed or text.start_with?(".") or text.start_with?("-")
    return Errors.invalid(
      "#{label} #{text.inspect} must be letters, digits, '.', '_' and '-', and not start with '.' or '-'",
    )
  end

  ok()
end

def plain_byte?(byte: Int) -> Bool
  (
    (byte >= 48 and byte <= 57) or
    (byte >= 65 and byte <= 90) or
    (byte >= 97 and byte <= 122) or
    byte == 46 or
    byte == 45 or
    byte == 95
  )
end

# A path of the project: relative, with no `..`.
def inside(label: String, path: String) -> Result[Void]
  odd = path.split("/").any? { |part| part == ".." or part.empty? }
  if path.empty? or path.start_with?("/") or odd
    return Errors.invalid("#{label} #{path.inspect} must be a path inside the project")
  end

  ok()
end

def paths_at(doc: Toml.Value) -> Result[List[String]]
  case Toml.get(doc, "tool.release.include")
    ok(Toml.Value.Array(items)) ->
      paths: List[String] = []
      for item in items
        case item
          Toml.Value.Str(path) ->
            try inside("include", path)
            paths = paths.push(path)
          _ -> return Errors.invalid("include must be a list of paths")
        end
      end

      ok(paths)
    ok(_) -> Errors.invalid("include must be a list of paths")
    error(_) -> ok([])
  end
end

# The `[native.NAME]` tables of the project: a library found by name (`system`) is listed; one stored by its path on
# this machine does not travel, so the release stops.
def natives(doc: Toml.Value) -> Result[List[String]]
  libraries: List[String] = []
  case Toml.get(doc, "native")
    ok(Toml.Value.Table(entries)) ->
      for name in entries.keys
        return Errors.invalid(stored(name)) if Toml.get(doc, "native.#{name}.build").ok?

        for platform in PLATFORMS
          case Toml.get(doc, "native.#{name}.#{platform}")
            ok(Toml.Value.Table(entry)) ->
              case entry.get("system")
                some(Toml.Value.Str(library)) -> libraries = libraries.push(library)
                _ -> return Errors.invalid(stored(name))
              end

            _ -> nil
          end
        end
      end

    _ -> nil
  end

  ok(libraries.sort)
end

def stored(name: String) -> String
  (
    "[native.#{name}] is a library stored by its path on this machine, which a release cannot move (agentica-lang/agentica#1753); use `system = \"libNAME.so\"`, found by name on the target"
  )
end

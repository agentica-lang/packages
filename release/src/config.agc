## What a release needs from the `agentica.toml` of the project: the name, the version and `[tool.release]`. It reads
## text and does no I/O.

import Errors from "errors"
import Names from "names"
import Natives from "natives"
import Toml from "std/toml"

## `name` and `version` make the folder `NAME-VERSION`; `entry` is the program; `include` are files or folders of the
## project copied into the release; `agentica` is the oldest version the project needs (empty: any); `system_libraries`
## are the native libraries found by name on the target.
struct Config
  name: String
  version: String
  entry: String
  include: List[String]
  agentica: String
  system_libraries: List[String]
end

## The config of the manifest text. `entry` (from the command line) wins over the `entry` of `[tool.release]` when it
## is not empty.
def parse(text: String, entry: String) -> Result[Config]
  parsed = Toml.parse(text)
  return Errors.invalid("agentica.toml: #{parsed.message}") if !parsed.ok?

  doc = parsed.unwrap!
  name = text_at(doc, "tool.release.name").unwrap_or(text_at(doc, "name").unwrap_or(""))
  try Names.word("name", name, "set name in agentica.toml")
  version = text_at(doc, "tool.release.version").unwrap_or("")
  try Names.word("version", version, "set version in [tool.release] of agentica.toml")
  program = entry
  if program.empty?
    program = text_at(doc, "tool.release.entry").unwrap_or("main.agc")
  end

  try Names.inside("entry", program)
  return Errors.invalid("entry #{program.inspect} is not an .agc file") if !program.end_with?(".agc")

  include = try paths_at(doc)
  libraries = try Natives.libraries(doc, "agentica.toml")
  ok(
    Config(
      name: name,
      version: version,
      entry: program,
      include: include,
      agentica: text_at(doc, "agentica").unwrap_or(""),
      system_libraries: libraries,
    ),
  )
end

private

# The folders that the release makes itself.
RESERVED = ["bin", "erts", "lib", "releases"]

def text_at(doc: Toml.Value, path: String) -> Optional[String]
  case Toml.get(doc, path)
    ok(Toml.Value.Str(text)) -> some(text)
    _ -> none
  end
end

def paths_at(doc: Toml.Value) -> Result[List[String]]
  case Toml.get(doc, "tool.release.include")
    ok(Toml.Value.Array(items)) ->
      paths: List[String] = []
      for item in items
        case item
          Toml.Value.Str(path) ->
            try Names.inside("include", path)
            if RESERVED.include?(path.split("/")[0])
              return Errors.invalid(
                "include #{path.inspect} is inside #{path.split("/")[0]}/, which the release makes",
              )
            end

            paths = paths.push(path)
          _ -> return Errors.invalid("include must be a list of paths")
        end
      end

      try apart(paths)
      ok(paths)
    ok(_) -> Errors.invalid("include must be a list of paths")
    error(_) -> ok([])
  end
end

# Two paths of `include` that are the same, or one inside the other, would be copied over each other.
def apart(paths: List[String]) -> Result[Void]
  for index in 0...paths.size
    for other in 0...paths.size
      same = index != other and (paths[index] == paths[other] or paths[other].start_with?("#{paths[index]}/"))
      return Errors.invalid("include #{paths[other].inspect} is in #{paths[index].inspect} already") if same
    end
  end

  ok()
end

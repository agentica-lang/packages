## The native libraries of a manifest. Only a library found by name on the target travels: every other shape is
## refused, so a form that a later Agentica adds is not shipped by accident. It does no I/O.

import Errors from "errors"
import Toml from "std/toml"

## The `system` libraries that the system `os` ("linux", "macos" or "windows") needs, from the `[native.NAME]` tables of
## `doc`, sorted and with no repeat; a list of candidates (`system = ["a", "b"]`) is one entry, `a or b`. The tables of
## the other systems are checked but not listed. `owner` names the manifest in an error.
def libraries(doc: Toml.Value, owner: String, os: String) -> Result[List[String]]
  found: List[String] = []
  case Toml.get(doc, "native")
    ok(Toml.Value.Table(entries)) ->
      for name in entries.keys
        found = found + try module(owner, name, entries.get(name), os)
      end

    ok(_) -> return Errors.invalid("#{owner}: native must be a table of [native.NAME] tables")
    error(_) -> nil
  end

  ok(found.uniq.sort)
end

private

PLATFORMS = ["linux", "macos", "windows"]
STORED = ["build", "prebuilt", "file"]

def module(owner: String, name: String, value: Optional[Toml.Value], os: String) -> Result[List[String]]
  case value
    some(Toml.Value.Table(platforms)) ->
      found: List[String] = []
      for platform in platforms.keys
        return Errors.invalid(stored(owner, name)) if STORED.include?(platform)
        return Errors.invalid(unknown(owner, name)) if !PLATFORMS.include?(platform)

        libraries = try entry(owner, name, platforms.get(platform))
        if platform == os
          found = found + libraries
        end
      end

      ok(found)
    _ -> Errors.invalid(unknown(owner, name))
  end
end

def entry(owner: String, name: String, value: Optional[Toml.Value]) -> Result[List[String]]
  case value
    some(Toml.Value.Table(fields)) ->
      return Errors.invalid(stored(owner, name)) if fields.keys.any? { |key| STORED.include?(key) }

      return Errors.invalid(unknown(owner, name)) if fields.keys != ["system"]

      case fields.get("system")
        some(Toml.Value.Str(library)) -> ok([library])
        some(Toml.Value.Array(items)) -> candidates(owner, name, items)
        _ -> Errors.invalid(unknown(owner, name))
      end

    _ -> Errors.invalid(unknown(owner, name))
  end
end

def candidates(owner: String, name: String, items: List[Toml.Value]) -> Result[List[String]]
  names: List[String] = []
  for item in items
    case item
      Toml.Value.Str(library) -> names = names.push(library)
      _ -> return Errors.invalid(unknown(owner, name))
    end
  end

  return Errors.invalid(unknown(owner, name)) if names.empty?

  ok([names.join(" or ")])
end

def stored(owner: String, name: String) -> String
  (
    "#{owner}: [native.#{name}] is a library stored by its path on this machine, which a release cannot move (agentica-lang/agentica#1753); use `system = \"libNAME.so\"`, found by name on the target"
  )
end

def unknown(owner: String, name: String) -> String
  (
    "#{owner}: [native.#{name}] has a shape that release does not know; only linux, macos and windows tables with `system = \"libNAME.so\"` are allowed"
  )
end

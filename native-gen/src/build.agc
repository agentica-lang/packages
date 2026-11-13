## The parts of `build` that do no I/O: where the library of a Rust module goes on each system, the `[native.NAME]`
## entry of `agentica.toml` that names it, and the library in the messages of `cargo build`.

import Toml from "std/toml"

## What `build` writes for a module: the text of `agentica.toml` (the same text when its entry is there already) and
## the library's path from the package folder.
struct Plan
  manifest: String
  file: String
end

## The library of the module `name` in `native/`, named as cargo names a cdylib on `os`: `native/libNAME.so` on
## linux, `native/libNAME.dylib` on macos, `native/NAME.dll` on windows.
def library_file(name: String, os: String) -> Result[String]
  ending = try extension(os)
  return ok("native/#{name}#{ending}") if os == "windows"

  ok("native/lib#{name}#{ending}")
end

## The ending of a cdylib on `os`: `.so`, `.dylib` or `.dll`.
def extension(os: String) -> Result[String]
  case os
    "linux" -> ok(".so")
    "macos" -> ok(".dylib")
    "windows" -> ok(".dll")
    _ -> error("[NATIVE-GEN-OS] build knows the libraries of linux, macos and windows, not of #{os.inspect}")
  end
end

## The manifest `text` without its `native` table, for reading the `.agc` before its library is built: each library
## of the file is then a bare name, which a check does not open.
def without_native(text: String) -> Result[String]
  case Toml.parse(text)
    ok(Toml.Value.Table(entries)) -> Toml.encode(Toml.Value.Table(entries.delete("native")))
    ok(_) -> error("not a table")
    error(e) -> error(e)
  end
end

## The manifest `text` (of the file at `path`) with the entry `OS = { file = "..." }` of `[native.NAME]`, and the
## library's file. An entry there already is kept, with its file. A missing one goes under the `[native.NAME]` line,
## or in a new table at the end. A `build` table (C sources), an entry without `file` or with one outside `native/`, a
## table written another way and a manifest that is not TOML are `[NATIVE-GEN-MANIFEST]`. The lines it adds end as
## the text's lines do (CRLF or LF).
def plan(path: String, text: String, name: String, os: String) -> Result[Plan]
  doc = try parsed(path, text)
  table = "native.#{name}"
  key = "#{table}.#{os}"
  if Toml.get(doc, "#{table}.build").ok?
    return error(
      "[NATIVE-GEN-MANIFEST] #{path}: #{table} has a build table, which builds C sources; a Rust module has #{key}",
    )
  end

  if Toml.get(doc, key).ok?
    case Toml.get(doc, "#{key}.file")
      ok(Toml.Value.Str(file)) if in_native?(file) -> return ok(Plan(manifest: text, file: file))
      ok(Toml.Value.Str(file)) ->
        return error("[NATIVE-GEN-MANIFEST] #{path}: #{key} has the file #{file.inspect}, which is not in native/")
      _ -> return error("[NATIVE-GEN-MANIFEST] #{path}: #{key} has no file, the path that build copies the library to")
    end
  end

  file = try library_file(name, os)
  entry = "#{os} = { file = #{file.inspect} }"
  by_hand = "[NATIVE-GEN-MANIFEST] #{path}: add #{key} = { file = #{file.inspect} } by hand; build cannot add it here"
  newline = "\n"
  if text.include?("\r\n")
    newline = "\r\n"
  end

  joined = ""
  if Toml.get(doc, table).ok?
    joined = under_header(text, table, entry, newline).unwrap_or("")
  else
    joined = "#{ended(text, newline)}#{newline}[#{table}]#{newline}#{entry}#{newline}"
  end

  # The text is checked again: a header line inside a multi-line string, or a `native` table written inline, gives
  # a text that is not TOML or that lacks the entry.
  case Toml.parse(joined)
    ok(done) if Toml.get(done, "#{key}.file") == ok(Toml.Value.Str(file)) -> ok(Plan(manifest: joined, file: file))
    _ -> error(by_hand)
  end
end

## The plan for the manifest `now`, read again before it is written: `planned`, made on the text `before`, when the
## file did not change meanwhile (cargo ran in between), or a new plan on `now`, which must name the same library file.
def replan(path: String, before: String, planned: Plan, now: String, name: String, os: String) -> Result[Plan]
  return ok(planned) if now == before

  again = try plan(path, now, name, os)
  if again.file != planned.file
    return error("[NATIVE-GEN-MANIFEST] #{path} changed during the build: it names #{again.file} now; run build again")
  end

  ok(again)
end

## The library that cargo built, from the lines it wrote with `--message-format=json-render-diagnostics`: the one file
## ending in `extension` of a `cdylib` target.
def library_in(lines: List[String], extension: String) -> Result[String]
  found = lines.flat_map do |line: String| cdylib_files(line, extension) end
  if found.size != 1
    return error(
      "[NATIVE-GEN-CARGO] cargo built #{found.size} libraries ending in #{extension}; build needs one (a cdylib)",
    )
  end

  ok(found[0])
end

private

# A line of `cargo build --message-format=json-render-diagnostics`; only a `compiler-artifact` has a target and files.
struct Message
  reason: String
  target: Optional[Target]
  filenames: Optional[List[String]]
end

struct Target
  kind: List[String]
end

# The files ending in `extension` of a message about a `cdylib` target; none for any other line.
def cdylib_files(line: String, extension: String) -> List[String]
  case JSON.decode(line, Message)
    ok(message) if message.reason == "compiler-artifact" and message.target.map(&cdylib?).unwrap_or(false) ->
      message.filenames.unwrap_or([]).select do |file: String| file.end_with?(extension) end
    _ -> []
  end
end

def cdylib?(target: Target) -> Bool = target.kind.include?("cdylib")

# `text` with `entry` on the line after its `[table]` line, which may end with a comment; none when the table, written
# as dotted keys or inline, has no such line. `newline` is "\r\n" for a text with CRLF lines.
def under_header(text: String, table: String, entry: String, newline: String) -> Optional[String]
  lines = text.split("\n")
  header = "[#{table}]"
  before = lines.take_while do |line: String| !header_line?(line, header) end
  return none if before.size == lines.size

  at = before.size + 1
  added = "#{entry}#{newline.slice(0, newline.length - 1)}"
  some(lines.take(at).push(added).concat(lines.drop(at)).join("\n"))
end

# Whether the library file `file` of an entry is a file in `native/`: no empty, `.` or `..` part.
def in_native?(file: String) -> Bool
  parts = file.replace("\\", "/").split("/")
  plain = parts.all? do |part: String| part != "" and part != "." and part != ".." end
  parts.size > 1 and parts[0] == "native" and plain
end

# Whether `line` is the table header `header`, with a comment after it or not.
def header_line?(line: String, header: String) -> Bool = line.split("#")[0].strip == header

def ended(text: String, newline: String) -> String
  return text if text.empty? or text.end_with?("\n")

  "#{text}#{newline}"
end

def parsed(path: String, text: String) -> Result[Toml.Value]
  case Toml.parse(text)
    ok(doc) -> ok(doc)
    error(e) -> error("[NATIVE-GEN-MANIFEST] #{path} is not TOML: #{e.message}")
  end
end

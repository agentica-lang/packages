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
## `[NATIVE-GEN-PREFIX]`, `[NATIVE-GEN-BLOCK]`, or the code of the diagnostic when the file does not check.

import Analysis from "std/analysis"
import CHeader from "src/header"

## The header of the one `extern module` block of the file at `path`. Its C names start with `prefix`, by default the
## last part of the block's library name up to its first `.` (`stats` for "stats" and for "native/stats.so").
export def header(path: String, prefix: String = "") -> Result[String]
  found = Analysis.native_modules(Analysis.open(Analysis.workspace()), path)
  if !found.ok?
    return error(diagnostic_text(found.message))
  end

  blocks = found.unwrap!.blocks
  if blocks.size != 1
    return error("[NATIVE-GEN-BLOCK] #{path} has #{blocks.size} extern module blocks; the header is made for one")
  end

  block = blocks[0]
  name = prefix
  if name.empty?
    name = default_prefix(block.library)
  end

  names = CHeader.prefix(name)
  if !names.ok?
    return error("[NATIVE-GEN-PREFIX] #{names.message}; choose one with --prefix")
  end

  made = CHeader.render(block, names.unwrap!, last_part(path))
  if !made.ok?
    return error("[NATIVE-GEN-NAME] #{made.message}")
  end

  return made
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

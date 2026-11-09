## The C header of one `extern module` block (pure): the typed prototypes the C author writes, and, under
## `PREFIX_NATIVE_IMPLEMENTATION`, the wrappers that decode the arguments and the tables of the module. Every
## signature, shape, mode and version comes from `std/analysis` as it is: the VM compares them byte for byte with the
## program's, so the header never writes one of its own.

import Analysis from "std/analysis"
import Codecs from "codecs"
import Collections from "collections"
import Names from "names"

# The table flags of the function modes and the kinds of the type rows that std/analysis gives.
MODES = {"short": "AN_SHORT", "dirty": "AN_DIRTY"}
KINDS = {"struct": "AN_STRUCT", "enum": "AN_ENUM"}
# Prefixes that would put the header's names in the namespace of the C API (`an_`, `AN_`, `agentica_native_init`) or
# of the helpers of native-gen (`ng_`).
RESERVED_PREFIXES = Set.new(["an", "ng", "agentica"])

## The C names of one header: the prefix of its functions and the same in capitals for its macros and constants.
export struct Prefix
  lower: String
  upper: String
end

## The prefix `text` for C names, or an error when it is not a C identifier or is one of the C API's.
export def prefix(text: String) -> Result[Prefix]
  if !Names.c_identifier?(text)
    return error("the prefix #{text.inspect} is not a C identifier")
  end

  lower = text.downcase
  if RESERVED_PREFIXES.include?(lower) or lower.start_with?("an_") or lower.start_with?("ng_")
    return error("the prefix #{text.inspect} is in the namespace of the C API or of native-gen")
  end

  # Functions take the prefix in lower case and constants in capitals, so `GL` cannot make a function and a constant
  # of one name.
  return ok(Prefix(lower: lower, upper: text.upcase))
end

## The header of `block`, declared in the file `source` (its name only, so the text does not depend on where it ran).
## An error starts with its code: `[NATIVE-GEN-NAME]` when two of its names map to one C identifier,
## `[NATIVE-GEN-UNKNOWN]` for a mode or a type kind that this version does not know.
export def render(block: Analysis.NativeBlock, names: Prefix, source: String) -> Result[String]
  for function in block.functions
    if !MODES.has_key?(function.mode)
      return error("[NATIVE-GEN-UNKNOWN] #{function.name} has the mode #{function.mode.inspect}")
    end

    try named(
      Names.distinct(
        function.parameters.map do |param: Analysis.NativeParameter|
          Names.Named(c: Names.parameter(param.name), source: "#{function.name}(#{param.name})")
        end,
      ),
    )
  end

  for type in block.types
    if !KINDS.has_key?(type.kind)
      return error("[NATIVE-GEN-UNKNOWN] #{type.name} has the kind #{type.kind.inspect}")
    end

    for member in type.members
      if type.kind == "enum" and !member.types.empty? and Names.macro?(member.name)
        return error("[NATIVE-GEN-NAME] #{type.name}.#{member.name} is a C macro, which its payload cannot be named")
      end
    end
  end

  codecs = Codecs.of(block, names.lower, names.upper)
  shelf = Collections.of(block, codecs)
  globals = global_names(block, names).concat(Codecs.global_names(codecs)).concat(Collections.global_names(shelf))
  try named(Names.distinct(globals))
  for fields in Codecs.field_names(codecs)
    try named(Names.distinct(fields))
  end

  lines = joined([
    opening(block, names, source),
    constants(block, names),
    Codecs.declarations(codecs),
    Collections.declarations(shelf),
    prototypes(block, names, shelf),
    implementation(block, names, shelf),
  ])

  return ok("#{lines.join("\n")}\n")
end

def named(distinct: Result[Void]) -> Result[Void]
  if !distinct.ok?
    return error("[NATIVE-GEN-NAME] #{distinct.message}")
  end

  return ok()
end

# Every C name the header declares at file scope, with the name of the block it comes from.
def global_names(block: Analysis.NativeBlock, names: Prefix) -> List[Names.Named]
  p = names.lower
  big = names.upper
  named = [
    Names.Named(c: "#{big}_NATIVE_H", source: "the include guard"),
    Names.Named(c: "#{big}_NATIVE_IMPLEMENTATION", source: "the implementation switch"),
    Names.Named(c: "#{big}_NATIVE_IMPLEMENTATION_DONE", source: "the implementation guard"),
    Names.Named(c: "agentica_native_init", source: "the export of the module"),
    Names.Named(c: "#{big}_NATIVE_MODULE", source: "the module macro"),
    Names.Named(c: "#{p}_native_functions", source: "the function table"),
    Names.Named(c: "#{p}_native_types", source: "the type table"),
    Names.Named(c: "#{p}_native_resources", source: "the resource table"),
  ]

  for function in block.functions
    c = Names.identifier(function.name)
    named = named.push(Names.Named(c: "#{p}_#{c}", source: function.name))
    named = named.push(Names.Named(c: "#{p}_native_#{c}", source: "the wrapper of #{function.name}"))
  end

  for type in block.types
    named = named.push(Names.Named(c: "#{big}_TYPE_#{type.name}", source: type.name))
    for member in type.members
      named = named.push(Names.Named(c: "#{big}_#{type.name}_#{member.name}", source: "#{type.name}.#{member.name}"))
    end
  end

  for resource in block.resources
    named = named.push(Names.Named(c: "#{big}_RESOURCE_#{resource.name}", source: resource.name))
    named = named.push(Names.Named(c: "#{big}_#{resource.name}_FREE", source: "the free of #{resource.name}"))
  end

  return named
end

# The guard of the file and of the API version, and the borrowed String and Bytes of the arguments.
def opening(block: Analysis.NativeBlock, names: Prefix, source: String) -> List[String]
  guard = "#{names.upper}_NATIVE_H"
  file = "#{names.lower}_native.h"
  lines = [
    "/* #{comment_safe("The C side of `extern module #{block.library.inspect}` in #{source}, made by native-gen.")}",
    "   Do not edit it: change the .agc and make it again. */",
    "#ifndef #{guard}",
    "#define #{guard}",
    "",
    "#include \"agentica_native.h\"",
    "",
    "#if AN_API_MAJOR != #{block.api_major}",
    "#error \"#{file} needs version #{block.api_major} of the native API (agentica_native.h)\"",
    "#endif",
  ]

  if block.api_minor > 0
    lines = lines.concat([
      "#if AN_API_MINOR < #{block.api_minor}",
      "#error \"#{file} needs version #{block.api_major}.#{block.api_minor} or later of the native API (agentica_native.h)\"",
      "#endif",
    ])
  end

  return lines.concat([
    "",
    "#ifdef __cplusplus",
    "extern \"C\" {",
    "#endif",
    "",
    "/* A String or Bytes argument, borrowed for the call: copy it to keep it. String data is UTF-8 with no NUL at its",
    "   end. Every header of this version of native-gen has these two, so one file can include several. */",
    "#ifndef NATIVE_GEN_SLICES_1",
    "#define NATIVE_GEN_SLICES_1",
    "typedef struct {",
    "  const char *data;",
    "  size_t len;",
    "} ng_str;",
    "typedef struct {",
    "  const uint8_t *data;",
    "  size_t len;",
    "} ng_buf;",
    "#endif",
  ])
end

# The rows of the type and resource tables, the fields and variants of each type, and the state of each resource.
def constants(block: Analysis.NativeBlock, names: Prefix) -> List[String]
  big = names.upper
  lines: List[String] = []
  if !block.types.empty?
    rows = numbered(block.types.map do |type: Analysis.NativeType| "#{big}_TYPE_#{type.name}" end)
    lines = lines.concat([
      "", "/* The rows of the type table: the TYPE of an_struct, an_enum and their getters. */", rows,
    ])
  end

  for type in block.types
    member_names = type.members.map do |member: Analysis.NativeMember| "#{big}_#{type.name}_#{member.name}" end
    members = numbered(member_names)
    if type.kind == "enum"
      tag = numbered_type(member_names, "#{names.lower}_#{type.name}_tag")
      lines = lines.concat(["", "/* The variants of #{type.name}, in declared order: the tag of its C value. */", tag])
    else
      lines = lines.concat(["", "/* The fields of #{type.name}, in declared order. */", members])
    end
  end

  if !block.resources.empty?
    rows = numbered(block.resources.map do |resource: Analysis.NativeResource| "#{big}_RESOURCE_#{resource.name}" end)
    lines = lines.concat([
      "",
      "/* The rows of the resource table: the TYPE of an_resource_new and an_get_resource. */",
      rows,
    ])
  end

  for resource in block.resources
    note = (
      "Define it, and #{big}_#{resource.name}_FREE (a void (*)(void *state), or NULL), before #{big}_NATIVE_MODULE."
    )

    if !resource.doc.empty?
      note = "#{resource.doc}\n\n#{note}"
    end

    lines = joined([lines, [""], doc_comment(note), ["struct #{names.lower}_#{resource.name}_state;"]])
  end

  return lines
end

# One enum of `items`, numbered from 0 in their order.
def numbered(items: List[String]) -> String
  return "enum { #{enum_rows(items)} };"
end

# The same enum as the type `name`.
def numbered_type(items: List[String], name: String) -> String
  return "typedef enum { #{enum_rows(items)} } #{name};"
end

def enum_rows(items: List[String]) -> String
  at = 0
  rows: List[String] = []
  for item in items
    rows = rows.push("#{item} = #{at}")
    at += 1
  end

  return rows.join(", ")
end

# One prototype per function, each with the `##` doc of its declaration.
def prototypes(block: Analysis.NativeBlock, names: Prefix, shelf: Collections.Shelf) -> List[String]
  lines: List[String] = []
  for function in block.functions
    typed = function.parameters.map do |param: Analysis.NativeParameter|
      "#{Collections.c_type(shelf, param.type)} #{Names.parameter(param.name)}"
    end

    params = ["an_env *env"].concat(typed)
    name = "#{names.lower}_#{Names.identifier(function.name)}"
    lines = joined([lines, [""], doc_comment(function.doc), ["an_term #{name}(#{params.join(", ")});"]])
  end

  return lines.concat(["", "#ifdef __cplusplus", "}", "#endif", "", "#endif"])
end

# The wrappers, the tables and the module macro, for the one .c file that defines the module.
def implementation(block: Analysis.NativeBlock, names: Prefix, shelf: Collections.Shelf) -> List[String]
  big = names.upper
  lines = [
    "",
    "/* Outside the include guard, so a file that included the header before it defined the switch still gets this",
    "   part; its own guard keeps it to one copy. */",
    "#if defined(#{big}_NATIVE_IMPLEMENTATION) && !defined(#{big}_NATIVE_IMPLEMENTATION_DONE)",
    "#define #{big}_NATIVE_IMPLEMENTATION_DONE",
    "/* Declared with C linkage, so a module built as C++ exports it under its C name. */",
    "#ifdef __cplusplus",
    "extern \"C\" {",
    "#endif",
    "AN_EXPORT const an_module *agentica_native_init(const an_api *api);",
    "#ifdef __cplusplus",
    "}",
    "#endif",
  ]

  lines = joined([lines, Codecs.definitions(shelf.codecs, !shelf.read.empty?), Collections.definitions(shelf)])
  for function in block.functions
    lines = joined([lines, [""], wrapper(function, names, shelf)])
  end

  return joined([lines, tables(block, names), ["#endif"]])
end

# The function of the table: it decodes each argument that has a C type (opens it, for a List or Map), fails the call
# at the first one that does not decode, and calls the author's typed function.
def wrapper(function: Analysis.NativeFunction, names: Prefix, shelf: Collections.Shelf) -> List[String]
  codecs = shelf.codecs
  c = Names.identifier(function.name)
  lines = ["static an_term #{names.lower}_native_#{c}(an_env *env, int argc, const an_term *argv) {", "  (void)argc;"]
  if function.parameters.empty?
    lines = lines.push("  (void)argv;")
  end

  if function.parameters.any? do |param: Analysis.NativeParameter| failable?(shelf, param.type) end
    lines = lines.push("  ng_fail fail;")
  end

  passed: List[String] = ["env"]
  at = 0
  for param in function.parameters
    local = "a#{at}"
    decoded = Codecs.decode_argument(codecs, param.type, local, at)
    if Collections.typed?(param.type)
      decoded = Collections.decode_argument(shelf, param.type, local, at)
    end

    if decoded.empty?
      passed = passed.push("argv[#{at}]")
    else
      lines = lines.concat(decoded)
      passed = passed.push(local)
    end

    at += 1
  end

  return lines.concat(["  return #{names.lower}_#{c}(#{passed.join(", ")});", "}"])
end

# Whether an argument of `type` fails the call with a path when it does not decode.
def failable?(shelf: Collections.Shelf, type: String) -> Bool
  return Codecs.embedded?(shelf.codecs, "", type) or Collections.typed?(type)
end

# The function and type tables, and the macro that ends the module's file with the resource table, which needs the
# author's state structs and free functions, so it is made where the macro is used.
def tables(block: Analysis.NativeBlock, names: Prefix) -> List[String]
  p = names.lower
  lines: List[String] = []
  functions = "NULL, 0"
  if !block.functions.empty?
    lines = lines.concat(["", "static const an_function #{p}_native_functions[] = {"])
    for function in block.functions
      c = Names.identifier(function.name)
      signature = c_string(function.signature)
      lines = lines.push("  {#{c_string(function.name)}, #{signature}, #{p}_native_#{c}, #{MODES[function.mode]}},")
    end

    lines = lines.push("};")
    functions = "#{p}_native_functions, #{block.functions.size}"
  end

  types = "NULL, 0"
  if !block.types.empty?
    lines = lines.concat(["", "static const an_type #{p}_native_types[] = {"])
    for type in block.types
      lines = lines.push("  {#{c_string(type.name)}, #{KINDS[type.kind]}, #{c_string(type.shape)}},")
    end

    lines = lines.push("};")
    types = "#{p}_native_types, #{block.types.size}"
  end

  return lines.concat(module_macro(block, names, functions, types))
end

def module_macro(block: Analysis.NativeBlock, names: Prefix, functions: String, types: String) -> List[String]
  big = names.upper
  library = c_string(block.library)
  lines = [
    "",
    "/* Ends the module's one .c file: the tables and agentica_native_init. LOAD is NULL or a const char *(*)(void)",
    "   that runs once at the first call, and refuses the module with the message it returns. */",
  ]

  if block.resources.empty?
    return lines.push(
      "#define #{big}_NATIVE_MODULE(LOAD) AN_MODULE_TABLES(#{library}, #{functions}, #{types}, NULL, 0, LOAD)",
    )
  end

  p = names.lower
  lines = lines.concat([
    "#define #{big}_NATIVE_MODULE(LOAD) \\",
    "  static const an_resource_type #{p}_native_resources[] = { \\",
  ])

  for resource in block.resources
    name = resource.name
    lines = lines.push("    {#{c_string(name)}, sizeof(struct #{p}_#{name}_state), #{big}_#{name}_FREE}, \\")
  end

  resources = "#{p}_native_resources, #{block.resources.size}"
  return lines.concat(["  }; \\", "  AN_MODULE_TABLES(#{library}, #{functions}, #{types}, #{resources}, LOAD)"])
end

# The lines of `parts`, in order.
def joined(parts: List[List[String]]) -> List[String]
  return parts.flat_map do |part: List[String]| part end
end

# `doc` as a C comment above a declaration; nothing for no doc.
def doc_comment(doc: String) -> List[String]
  if doc.empty?
    return []
  end

  lines = comment_safe(doc).split("\n")
  last = lines.size - 1
  at = 0
  out: List[String] = []
  for line in lines
    lead = "   "
    if at == 0
      lead = "/* "
    end

    text = "#{lead}#{line}"
    if line.empty?
      text = ""
    end

    if at == last
      text = "#{text} */"
    end

    out = out.push(text)
    at += 1
  end

  return out
end

# `text` with no `*/`, which would end the comment that holds it, no `/*`, which -Wcomment refuses inside one, and no
# `??`, which starts a trigraph (`-std=c11` reads them).
def comment_safe(text: String) -> String
  return text.replace("*/", "* /").replace("/*", "/ *").replace("??", "? ?")
end

# `text` as a C string literal: a quote, a backslash, a control character and the second `?` of `??` (a trigraph)
# escaped, the control characters in octal, three digits, so the next character never joins the escape.
def c_string(text: String) -> String
  out: List[String] = []
  previous = ""
  for c in text.split("")
    code = c.code
    if c == "\"" or c == "\\" or (c == "?" and previous == "?")
      out = out.push("\\#{c}")
    elsif code < 32 or code == 127
      out = out.push("\\#{octal(code)}")
    else
      out = out.push(c)
    end

    previous = c
  end

  return "\"#{out.join("")}\""
end

# `code` (0 to 127) in three octal digits.
def octal(code: Int) -> String
  return "#{code / 64}#{code / 8 % 8}#{code % 8}"
end

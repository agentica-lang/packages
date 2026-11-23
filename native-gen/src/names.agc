## The C names of an `extern module` block (pure): a function name as a C identifier, a parameter name that is a C or
## C++ keyword, and the check that no two names of a header map to one identifier. `validate` is what the header and
## the Rust file both check of a block.

import Analysis from "std/analysis"

## The modes of the functions and the kinds of the type rows that std/analysis gives, each with its flag in the C
## tables: the ones this version knows.
MODES = {"short": "AN_SHORT", "dirty": "AN_DIRTY"}
KINDS = {"struct": "AN_STRUCT", "enum": "AN_ENUM"}

## The line of a function's `##` doc that marks it fresh: the resources it makes own all their memory, so an arena that
## keeps its result keeps it alone (`AN_FRESH`, API 1.5). The row is `AN_FRESH` or'd with its mode, and the header
## needs API 1.5.
FRESH_MARK = "@fresh"

## The first minor version of the native API that has `AN_FRESH`.
FRESH_MINOR = 5

## A C identifier of the header and the name of the block it comes from (`summary`, `Cell.Number`).
struct Named
  c: String
  source: String
end

## Whether the doc of `function` has a line that is `@fresh`.
def fresh?(function: Analysis.NativeFunction) -> Bool
  function.doc.split("\n").any? do |line: String| line.strip == FRESH_MARK end
end

## The doc of `function` without its `@fresh` line, and without the blank lines that the line leaves at an end of the
## doc or twice in a row.
def doc_of(function: Analysis.NativeFunction) -> String
  return function.doc if !fresh?(function)

  kept: List[String] = []
  after_mark = false
  for line in function.doc.split("\n")
    if line.strip == FRESH_MARK
      after_mark = true
    elsif !(after_mark and line.strip.empty? and (kept.empty? or kept.last.strip.empty?))
      after_mark = false
      kept = kept.push(line)
    end
  end

  trimmed(kept).join("\n")
end

## `lines` without the blank lines at its start and its end.
def trimmed(lines: List[String]) -> List[String]
  first = 0
  while first < lines.size and lines[first].strip.empty?
    first += 1
  end

  last = lines.size
  while last > first and lines[last - 1].strip.empty?
    last -= 1
  end

  lines.drop(first).take(last - first)
end

## The flags of the row of `function` in the function table: its mode, and `AN_FRESH` when it is marked.
def flags(function: Analysis.NativeFunction) -> String
  return "#{MODES[function.mode]} | AN_FRESH" if fresh?(function)

  MODES[function.mode]
end

## The version of the native API that `block` needs: the one `std/analysis` gives, or 1.5 when a function is fresh.
def api_minor(block: Analysis.NativeBlock) -> Int
  if block.api_minor >= FRESH_MINOR or !block.functions.any? do |f: Analysis.NativeFunction| fresh?(f) end
    return block.api_minor
  end

  FRESH_MINOR
end

## Whether `name` is a macro of the C or C++ standard library that a variant with a payload cannot be named after: the
## payload is a member of a union, which the macro would replace.
def macro?(name: String) -> Bool = MACROS.include?(name)

## An error when a line of the doc of `function` starts with `@` and is not a marker (`@Fresh` and `@fresh.` are
## typos, and the namespace is reserved), or when `@fresh` is on a function whose result reaches no resource.
def check_markers(block: Analysis.NativeBlock, function: Analysis.NativeFunction) -> Result[Void]
  for line in function.doc.split("\n")
    text = line.strip
    if text.start_with?("@") and text != FRESH_MARK
      return error(
        "[NATIVE-GEN-UNKNOWN] #{function.name} has the doc line #{text.inspect}, and #{FRESH_MARK} is the only marker",
      )
    end
  end

  if fresh?(function) and !makes_resource?(block, function)
    return error(
      "[NATIVE-GEN-FRESH] #{function.name} is marked #{FRESH_MARK}, but its result #{function.result} has no resource",
    )
  end

  ok()
end

## Whether the result of `function` is, or holds, a resource of `block`.
def makes_resource?(block: Analysis.NativeBlock, function: Analysis.NativeFunction) -> Bool
  names = block.resources.map do |resource: Analysis.NativeResource| resource.name end
  function.types_out.any? do |name: String| names.include?(name) end
end

## A name of the block as a C identifier: `empty?` is `empty_p` and `save!` is `save_bang`.
def identifier(name: String) -> String
  return "#{name.slice(0, name.length - 1)}_p" if name.end_with?("?")

  return "#{name.slice(0, name.length - 1)}_bang" if name.end_with?("!")

  name
end

## A parameter name as a C identifier, with a trailing `_` when it is a keyword of C or C++, `env`, a type or macro a
## prototype may use, or starts with `an_` or `ng_`.
def parameter(name: String) -> String
  return "#{name}_" if RESERVED.include?(name) or RESERVED_STARTS.any? do |start: String| name.start_with?(start) end

  name
end

## Whether `text` is a C identifier: a letter or `_`, then letters, digits and `_`, ASCII only.
def c_identifier?(text: String) -> Bool
  return false if text.empty?

  at = 0
  for c in text.split("")
    code = c.code
    letter = (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95
    digit = code >= 48 and code <= 57
    return false if !letter and !(digit and at > 0)

    at += 1
  end

  true
end

## An error `[NATIVE-GEN-NAME]` that names the first two names of `named` that map to one `target` (a C identifier,
## a Rust name); ok when all are distinct.
def distinct(named: List[Named], target: String = "C identifier") -> Result[Void]
  seen: Map[String, String] = {}
  for name in named
    if seen.has_key?(name.c)
      return error("[NATIVE-GEN-NAME] #{seen[name.c]} and #{name.source} both map to the #{target} #{name.c}")
    end

    seen = seen.put(name.c, name.source)
  end

  ok()
end

## Whether `block` has only the modes and kinds this version knows (`[NATIVE-GEN-UNKNOWN]`), and no two parameters of a
## function, or fields of a struct, that `rename` maps to one `target` (`[NATIVE-GEN-NAME]`).
def validate(block: Analysis.NativeBlock, target: String, rename: Fn[String, String]) -> Result[Void]
  for function in block.functions
    if !MODES.has_key?(function.mode)
      return error("[NATIVE-GEN-UNKNOWN] #{function.name} has the mode #{function.mode.inspect}")
    end

    params = function.parameters.map do |param: Analysis.NativeParameter|
      Named(c: rename.call(param.name), source: "#{function.name}(#{param.name})")
    end

    try distinct(params, target)
    try check_markers(block, function)
  end

  for type in block.types
    return error("[NATIVE-GEN-UNKNOWN] #{type.name} has the kind #{type.kind.inspect}") if !KINDS.has_key?(type.kind)

    if type.kind == "struct"
      fields = type.members.map do |member: Analysis.NativeMember|
        Named(c: rename.call(member.name), source: "#{type.name}.#{member.name}")
      end

      try distinct(fields, target)
    end
  end

  ok()
end

private

# The words a parameter name cannot be in C11 or C++ (the header compiles as both), `env`, the first parameter of
# every prototype, and the names of the types and macros a prototype or the C file may use (`int64_t`, `errno`). Such
# a name gets a trailing `_`, as does one in the namespace of the C API (`an_`) or of native-gen's types (`ng_`).
RESERVED = Set.new([
  "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor", "bool", "break", "case", "catch", "char",
  "char16_t", "char32_t", "char8_t", "class", "co_await", "co_return", "co_yield", "compl", "concept", "const",
  "const_cast", "consteval", "constexpr", "constinit", "continue", "decltype", "default", "delete", "do", "double",
  "dynamic_cast", "else", "enum", "env", "explicit", "export", "extern", "false", "float", "for", "friend", "goto",
  "if", "inline", "int", "long", "mutable", "namespace", "new", "noexcept", "not", "not_eq", "nullptr", "operator",
  "or", "or_eq", "private", "protected", "public", "register", "reinterpret_cast", "requires", "restrict", "return",
  "short", "signed", "sizeof", "static", "static_assert", "static_cast", "struct", "switch", "template", "this",
  "thread_local", "throw", "true", "try", "typedef", "typeid", "typename", "union", "unsigned", "using", "virtual",
  "void", "volatile", "wchar_t", "while", "xor", "xor_eq", "int64_t", "uint8_t", "uint32_t", "size_t", "errno",
])
RESERVED_STARTS = ["an_", "ng_"]
# The macros of the C and C++ standard headers that a CamelCase variant name can be (all capitals).
MACROS = Set.new([
  "NULL", "EOF", "BUFSIZ", "FILENAME_MAX", "FOPEN_MAX", "TMP_MAX", "L_tmpnam", "SEEK_SET", "SEEK_CUR", "SEEK_END",
  "EXIT_SUCCESS", "EXIT_FAILURE", "RAND_MAX", "MB_CUR_MAX", "CHAR_BIT", "CHAR_MIN", "CHAR_MAX", "INT_MIN", "INT_MAX",
  "UINT_MAX", "LONG_MIN", "LONG_MAX", "LLONG_MIN", "LLONG_MAX", "SIZE_MAX", "INT8_MIN", "INT8_MAX", "INT16_MIN",
  "INT16_MAX", "INT32_MIN", "INT32_MAX", "INT64_MIN", "INT64_MAX", "UINT8_MAX", "UINT16_MAX", "UINT32_MAX",
  "UINT64_MAX", "INFINITY", "NAN", "HUGE_VAL", "EDOM", "ERANGE", "EILSEQ", "SIGINT", "SIGTERM", "SIGABRT", "SIGSEGV",
  "SIGFPE", "SIGILL", "CLOCKS_PER_SEC", "BOOL", "TRUE", "FALSE", "AN_EXPORT", "AN_API_MAJOR", "AN_API_MINOR",
  "AN_SHORT", "AN_DIRTY", "AN_STRUCT", "AN_ENUM", "AN_COUNT",
])

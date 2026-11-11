## The C names of an `extern module` block (pure): a function name as a C identifier, a parameter name that is a C or
## C++ keyword, and the check that no two names of a header map to one identifier. `validate` is what the header and
## the Rust file both check of a block.

import Analysis from "std/analysis"

## The modes of the functions and the kinds of the type rows that std/analysis gives, each with its flag in the C
## tables: the ones this version knows.
export MODES = {"short": "AN_SHORT", "dirty": "AN_DIRTY"}
export KINDS = {"struct": "AN_STRUCT", "enum": "AN_ENUM"}

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

## A C identifier of the header and the name of the block it comes from (`summary`, `Cell.Number`).
export struct Named
  c: String
  source: String
end

## Whether `name` is a macro of the C or C++ standard library that a variant with a payload cannot be named after: the
## payload is a member of a union, which the macro would replace.
export def macro?(name: String) -> Bool = MACROS.include?(name)

## A name of the block as a C identifier: `empty?` is `empty_p` and `save!` is `save_bang`.
export def identifier(name: String) -> String
  return "#{name.slice(0, name.length - 1)}_p" if name.end_with?("?")

  return "#{name.slice(0, name.length - 1)}_bang" if name.end_with?("!")

  name
end

## A parameter name as a C identifier, with a trailing `_` when it is a keyword of C or C++, `env`, a type or macro a
## prototype may use, or starts with `an_` or `ng_`.
export def parameter(name: String) -> String
  return "#{name}_" if RESERVED.include?(name) or RESERVED_STARTS.any? do |start: String| name.start_with?(start) end

  name
end

## Whether `text` is a C identifier: a letter or `_`, then letters, digits and `_`, ASCII only.
export def c_identifier?(text: String) -> Bool
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
export def distinct(named: List[Named], target: String = "C identifier") -> Result[Void]
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
export def validate(block: Analysis.NativeBlock, target: String, rename: Fn[String, String]) -> Result[Void]
  for function in block.functions
    if !MODES.has_key?(function.mode)
      return error("[NATIVE-GEN-UNKNOWN] #{function.name} has the mode #{function.mode.inspect}")
    end

    params = function.parameters.map do |param: Analysis.NativeParameter|
      Named(c: rename.call(param.name), source: "#{function.name}(#{param.name})")
    end

    try distinct(params, target)
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

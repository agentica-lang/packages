## The C names of an `extern module` block (pure): a function name as a C identifier, a parameter name that is a C or
## C++ keyword, and the check that no two names of a header map to one identifier.

# The words a parameter name cannot be in C11 or C++ (the header compiles as both), and `env`, the first parameter of
# every prototype. Such a name gets a trailing `_`.
RESERVED = Set.new([
  "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor", "bool", "break", "case", "catch", "char",
  "char16_t", "char32_t", "char8_t", "class", "co_await", "co_return", "co_yield", "compl", "concept", "const",
  "const_cast", "consteval", "constexpr", "constinit", "continue", "decltype", "default", "delete", "do", "double",
  "dynamic_cast", "else", "enum", "env", "explicit", "export", "extern", "false", "float", "for", "friend", "goto",
  "if", "inline", "int", "long", "mutable", "namespace", "new", "noexcept", "not", "not_eq", "nullptr", "operator",
  "or", "or_eq", "private", "protected", "public", "register", "reinterpret_cast", "requires", "restrict", "return",
  "short", "signed", "sizeof", "static", "static_assert", "static_cast", "struct", "switch", "template", "this",
  "thread_local", "throw", "true", "try", "typedef", "typeid", "typename", "union", "unsigned", "using", "virtual",
  "void", "volatile", "wchar_t", "while", "xor", "xor_eq",
])

## A C identifier of the header and the name of the block it comes from (`summary`, `Cell.Number`).
export struct Named
  c: String
  source: String
end

## A name of the block as a C identifier: `empty?` is `empty_p` and `save!` is `save_bang`.
export def identifier(name: String) -> String
  if name.end_with?("?")
    return "#{name.slice(0, name.length - 1)}_p"
  end

  if name.end_with?("!")
    return "#{name.slice(0, name.length - 1)}_bang"
  end

  return name
end

## A parameter name as a C identifier, with a trailing `_` when it is a keyword of C or C++, or `env`.
export def parameter(name: String) -> String
  if RESERVED.include?(name)
    return "#{name}_"
  end

  return name
end

## Whether `text` is a C identifier: a letter or `_`, then letters, digits and `_`, ASCII only.
export def c_identifier?(text: String) -> Bool
  if text.empty?
    return false
  end

  at = 0
  for c in text.split("")
    code = c.code
    letter = (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 95
    digit = code >= 48 and code <= 57
    if !letter and !(digit and at > 0)
      return false
    end

    at += 1
  end

  return true
end

## An error that names the first two names of `named` that map to one C identifier; ok when all are distinct.
export def distinct(named: List[Named]) -> Result[Void]
  seen: Map[String, String] = {}
  for name in named
    if seen.has_key?(name.c)
      return error("#{seen[name.c]} and #{name.source} both map to the C identifier #{name.c}")
    end

    seen = seen.put(name.c, name.source)
  end

  return ok()
end

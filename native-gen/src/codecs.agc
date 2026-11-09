## The C codecs of the structs of a block (pure): a typedef per struct, `_get` for the structs the parameters reach and
## `_make` for those the results reach. A field of a struct of the block is embedded by value, unless that struct leads
## back to its owner, where it stays a term. A failed decode names the path to the bad part: `Line.from.x: expected
## Int`.

import Analysis from "std/analysis"
import Names from "names"

# The C type of a field of each scalar type; others are a term or an embedded struct.
SCALARS = {"Int": "int64_t", "Float": "double", "Bool": "bool", "String": "ng_str", "Bytes": "ng_buf"}
# The getter and the maker of `agentica_native.h` for each scalar type; those of SLICES take `data` and `len`.
GETTERS = {
  "Int": "an_get_int",
  "Float": "an_get_float",
  "Bool": "an_get_bool",
  "String": "an_get_string",
  "Bytes": "an_get_bytes",
}
MAKERS = {"Int": "an_int", "Float": "an_float", "Bool": "an_bool", "String": "an_string", "Bytes": "an_bytes"}
SLICES = Set.new(["String", "Bytes"])

## The structs of a block and what the C side needs of them: `lower` and `upper` the prefix of the C names, `read` the
## structs the parameters reach (they get a `_get`), `made` those the results reach (`_make`), and `edges` the structs
## each one names in a field, which decide what is embedded.
export struct Plan
  lower: String
  upper: String
  types: List[Analysis.NativeType]
  read: Set[String]
  made: Set[String]
  edges: Map[String, List[String]]
end

## The codecs of the structs of `block`, whose C names start with `lower` (and `upper` in capitals).
export def of(block: Analysis.NativeBlock, lower: String, upper: String) -> Plan
  structs = block.types.select do |type: Analysis.NativeType| type.kind == "struct" end
  known = Set.new(structs.map do |type: Analysis.NativeType| type.name end)
  read: Set[String] = Set.new([])
  made: Set[String] = Set.new([])
  for function in block.functions
    read = read.union(Set.new(function.types_in).intersection(known))
    made = made.union(Set.new(function.types_out).intersection(known))
  end

  edges: Map[String, List[String]] = {}
  for type in structs
    named: List[String] = []
    for member in type.members
      named = named.concat(member.types.select do |t: String| known.include?(t) end)
    end

    edges = edges.put(type.name, named)
  end

  return Plan(lower: lower, upper: upper, types: structs, read: read, made: made, edges: edges)
end

## The C type of a parameter or field of type `type` in `owner` ("" for a parameter): a scalar, an embedded struct, or
## a term.
export def c_type(codecs: Plan, owner: String, type: String) -> String
  if SCALARS.has_key?(type)
    return SCALARS[type]
  end

  if embedded?(codecs, owner, type)
    return "#{codecs.lower}_#{type}"
  end

  return "an_term"
end

## Whether a value of `type` in `owner` ("" for a parameter) is a C struct, not a term: a struct of the block that does
## not lead back to `owner`.
export def embedded?(codecs: Plan, owner: String, type: String) -> Bool
  return codecs.edges.has_key?(type) and !reaches?(codecs, type, owner)
end

## The C names the codecs declare, with the names they come from, and the fields of each struct, which must differ
## within it.
export def global_names(codecs: Plan) -> List[Names.Named]
  p = codecs.lower
  named: List[Names.Named] = []
  for type in codecs.types
    name = type.name
    named = named.push(Names.Named(c: "#{p}_#{name}", source: name))

    if codecs.read.include?(name)
      named = named.push(Names.Named(c: "#{p}_#{name}_get", source: "the get of #{name}"))
      named = named.push(Names.Named(c: "#{p}_native_get_#{name}", source: "the decoder of #{name}"))
    end

    if codecs.made.include?(name)
      named = named.push(Names.Named(c: "#{p}_#{name}_make", source: "the make of #{name}"))
    end
  end

  return named
end

## The C names of the fields of each struct, each list of which must be distinct.
export def field_names(codecs: Plan) -> List[List[Names.Named]]
  return codecs.types.map do |type: Analysis.NativeType|
    type.members.map do |member: Analysis.NativeMember|
      Names.Named(c: Names.parameter(member.name), source: "#{type.name}.#{member.name}")
    end
  end
end

## The typedefs, in an order where each comes after the types it embeds, and the prototypes of the codecs.
export def declarations(codecs: Plan) -> List[String]
  if codecs.types.empty?
    return []
  end

  lines = [
    "",
    "/* The structs as C values. A String or Bytes in them is borrowed, a term lasts for the call: keep them in C",
    "   locals. _get reads a term into OUT; false when it is not one, and then the call has failed with the path of the",
    "   first bad part. A function whose signature does not reach the struct reads none (\"Point: expected Point\").",
    "   _make makes a term. */",
  ]

  for type in ordered(codecs)
    lines = joined([lines, [""], typedef(codecs, type), prototypes(codecs, type)])
  end

  return lines
end

## The definitions of the codecs, for the implementation part of the header.
export def definitions(codecs: Plan) -> List[String]
  lines: List[String] = []
  if !codecs.read.empty?
    lines = lines.concat(failures())
  end

  for type in ordered(codecs)
    if codecs.read.include?(type.name)
      lines = joined([lines, [""], decoder(codecs, type), [""], public_get(codecs, type)])
    end

    if codecs.made.include?(type.name)
      lines = joined([lines, [""], maker(codecs, type)])
    end
  end

  return lines
end

## The statements of a wrapper that decode argument `at` of `type` into `local`: a scalar answers an_badarg when it
## does not decode, a struct fails the call with the path of the bad part. Nothing for a term.
export def decode_argument(codecs: Plan, type: String, local: String, at: Int) -> List[String]
  declared = "  #{c_type(codecs, "", type)} #{local};"
  if SLICES.include?(type)
    into = "&#{local}.data, &#{local}.len"
    return [declared, "  if (!#{GETTERS[type]}(env, argv[#{at}], #{into})) return an_badarg(env, #{at});"]
  end

  if GETTERS.has_key?(type)
    return [declared, "  if (!#{GETTERS[type]}(env, argv[#{at}], &#{local})) return an_badarg(env, #{at});"]
  end

  if embedded?(codecs, "", type)
    getter = "#{codecs.lower}_native_get_#{type}"
    return [
      declared,
      "  if (!#{getter}(env, argv[#{at}], &#{local}, &fail)) return ng_fail_argument(env, &fail, \"#{type}\", #{at});",
    ]
  end

  return []
end

# Whether `to` is `from` or a struct that `from` names in a field, at any depth.
def reaches?(codecs: Plan, from: String, to: String) -> Bool
  seen: Set[String] = Set.new([])
  pending = [from]
  while !pending.empty?
    at = pending[pending.size - 1]
    pending = pending.take(pending.size - 1)
    if at == to
      return true
    end

    if !seen.include?(at)
      seen = seen.add(at)
      pending = pending.concat(codecs.edges.get(at, []))
    end
  end

  return false
end

# The types, each after those it embeds, else in the order of the block.
def ordered(codecs: Plan) -> List[Analysis.NativeType]
  done: Set[String] = Set.new([])
  out: List[Analysis.NativeType] = []
  for type in codecs.types
    for name in emit_order(codecs, type.name, done)
      done = done.add(name)
      out = out.push(codecs.types.find do |t: Analysis.NativeType| t.name == name end.unwrap!)
    end
  end

  return out
end

# The names to emit for `name`, those it embeds first, leaving out those in `done`.
def emit_order(codecs: Plan, name: String, done: Set[String]) -> List[String]
  if done.include?(name)
    return []
  end

  out: List[String] = []
  emitted = done
  for inner in codecs.edges.get(name, [])
    if embedded?(codecs, name, inner)
      for found in emit_order(codecs, inner, emitted)
        emitted = emitted.add(found)
        out = out.push(found)
      end
    end
  end

  return out.push(name)
end

def typedef(codecs: Plan, type: Analysis.NativeType) -> List[String]
  fields = type.members.map do |member: Analysis.NativeMember|
    "  #{c_type(codecs, type.name, member.types[0])} #{Names.parameter(member.name)};"
  end

  if fields.empty?
    fields = ["  char empty;"]
  end

  return joined([["typedef struct {"], fields, ["} #{codecs.lower}_#{type.name};"]])
end

def prototypes(codecs: Plan, type: Analysis.NativeType) -> List[String]
  name = "#{codecs.lower}_#{type.name}"
  lines: List[String] = []
  if codecs.read.include?(type.name)
    lines = lines.push("bool #{name}_get(an_env *env, an_term t, #{name} *out);")
  end

  if codecs.made.include?(type.name)
    lines = lines.push("an_term #{name}_make(an_env *env, const #{name} *value);")
  end

  return lines
end

# The helpers of a failed decode, shared by every header of this version of native-gen. The path is made only when a
# decode fails, from the inside out, so a decode that succeeds pays nothing for it.
def failures() -> List[String]
  return [
    "",
    "#ifndef NATIVE_GEN_FAIL_1",
    "#define NATIVE_GEN_FAIL_1",
    "#include <stdio.h>",
    "#include <string.h>",
    "",
    "/* Where a decode failed: the path from the outer value in, and the type that was expected there. */",
    "typedef struct {",
    "  char path[192];",
    "  size_t len;",
    "  bool cut;",
    "  const char *expected;",
    "} ng_fail;",
    "",
    "static inline bool ng_expected(ng_fail *fail, const char *expected) {",
    "  fail->path[0] = '\\0';",
    "  fail->len = 0;",
    "  fail->cut = false;",
    "  fail->expected = expected;",
    "  return false;",
    "}",
    "",
    "/* Puts SEGMENT in front of the path. The first one that does not fit becomes \"...\" and ends the path, which",
    "   keeps its inner part. */",
    "static inline bool ng_at(ng_fail *fail, const char *segment) {",
    "  size_t n = strlen(segment), dot = fail->len > 0 ? 1 : 0;",
    "  if (fail->cut) return false;",
    "  if (n + dot + fail->len >= sizeof fail->path) {",
    "    fail->cut = true;",
    "    segment = \"...\";",
    "    n = 3;",
    "    if (n + dot + fail->len >= sizeof fail->path) return false;",
    "  }",
    "  memmove(fail->path + n + dot, fail->path, fail->len + 1);",
    "  memcpy(fail->path, segment, n);",
    "  if (dot) fail->path[n] = '.';",
    "  fail->len += n + dot;",
    "  return false;",
    "}",
    "",
    "static inline bool ng_leaf(ng_fail *fail, const char *expected, const char *segment) {",
    "  ng_expected(fail, expected);",
    "  return ng_at(fail, segment);",
    "}",
    "",
    "/* Fails the call with \"WHERE TYPE.PATH: expected X\". */",
    "static inline bool ng_raise(an_env *env, const char *where, const char *type, ng_fail *fail) {",
    "  char message[256];",
    "  ng_at(fail, type);",
    "  snprintf(message, sizeof message, \"%s%s: expected %s\", where, fail->path, fail->expected);",
    "  an_raise(env, message);",
    "  return false;",
    "}",
    "",
    "static inline an_term ng_fail_argument(an_env *env, ng_fail *fail, const char *type, int index) {",
    "  char where[32];",
    "  snprintf(where, sizeof where, \"argument %d: \", index + 1);",
    "  ng_raise(env, where, type, fail);",
    "  return an_void(env);",
    "}",
    "#endif",
  ]
end

# The decoder of the struct `type` into its C value, which records where it failed in `fail`.
def decoder(codecs: Plan, type: Analysis.NativeType) -> List[String]
  p = codecs.lower
  name = type.name
  head = "static bool #{p}_native_get_#{name}(an_env *env, an_term t, #{p}_#{name} *out, ng_fail *fail) {"
  if type.members.empty?
    return [head, "  (void)env;", "  (void)t;", "  (void)out;", "  (void)fail;", "  return true;", "}"]
  end

  row = "#{codecs.upper}_TYPE_#{name}"
  lines = [head, "  an_term x;"]
  at = 0
  for member in type.members
    lines = lines.push("  if (!an_get_field(env, t, #{row}, #{at}, &x)) return ng_expected(fail, \"#{name}\");")
    lines = lines.concat(
      decode_part(codecs, name, member.types[0], "out->#{Names.parameter(member.name)}", member.name),
    )

    at += 1
  end

  return lines.concat(["  return true;", "}"])
end

# The statement that reads the term `x` of `type` into `target`, or fails at `segment`.
def decode_part(codecs: Plan, owner: String, type: String, target: String, segment: String) -> List[String]
  if SLICES.include?(type)
    into = "&#{target}.data, &#{target}.len"
    return ["  if (!#{GETTERS[type]}(env, x, #{into})) return ng_leaf(fail, \"#{type}\", \"#{segment}\");"]
  end

  if GETTERS.has_key?(type)
    return ["  if (!#{GETTERS[type]}(env, x, &#{target})) return ng_leaf(fail, \"#{type}\", \"#{segment}\");"]
  end

  if embedded?(codecs, owner, type)
    getter = "#{codecs.lower}_native_get_#{type}"
    return ["  if (!#{getter}(env, x, &#{target}, fail)) return ng_at(fail, \"#{segment}\");"]
  end

  return ["  #{target} = x;"]
end

def public_get(codecs: Plan, type: Analysis.NativeType) -> List[String]
  p = codecs.lower
  name = type.name
  return [
    "bool #{p}_#{name}_get(an_env *env, an_term t, #{p}_#{name} *out) {",
    "  ng_fail fail;",
    "  return #{p}_native_get_#{name}(env, t, out, &fail) || ng_raise(env, \"\", \"#{name}\", &fail);",
    "}",
  ]
end

def maker(codecs: Plan, type: Analysis.NativeType) -> List[String]
  p = codecs.lower
  name = type.name
  head = "an_term #{p}_#{name}_make(an_env *env, const #{p}_#{name} *value) {"
  row = "#{codecs.upper}_TYPE_#{name}"
  if type.members.empty?
    return [head, "  (void)value;", "  return an_struct(env, #{row}, NULL);", "}"]
  end

  lines = [head, "  an_term fields[#{type.members.size}];"]
  at = 0
  for member in type.members
    value = encoded(codecs, name, member.types[0], "value->#{Names.parameter(member.name)}")
    lines = lines.push("  fields[#{at}] = #{value};")
    at += 1
  end

  return lines.concat(["  return an_struct(env, #{row}, fields);", "}"])
end

# The term of the C value `source` of `type`.
def encoded(codecs: Plan, owner: String, type: String, source: String) -> String
  if SLICES.include?(type)
    return "#{MAKERS[type]}(env, #{source}.data, #{source}.len)"
  end

  if MAKERS.has_key?(type)
    return "#{MAKERS[type]}(env, #{source})"
  end

  if embedded?(codecs, owner, type)
    return "#{codecs.lower}_#{type}_make(env, &#{source})"
  end

  return source
end

def joined(parts: List[List[String]]) -> List[String]
  return parts.flat_map do |part: List[String]| part end
end

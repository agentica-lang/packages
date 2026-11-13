## The typed Lists, Maps, Optionals and Results of a block (pure). A List or Map that a parameter reaches is read lazily
## through a cursor: `_open` and `_next`, which gives 1 for an item, 0 at the end and -1 for a bad item (the call has
## then failed with its path, `List[Point].2.x: expected Int`), and never copies to an array. One that a result reaches
## is made with a builder: `_begin`, `_push` (`_put` for a Map) and `_end`. An Optional or Result that is read is a C
## struct (`some` or `ok`, the value, and the error message of a Result); one that is made has a constructor, `_some`
## or `_ok`. An item is a C value as in the codecs, one of these four that is read is its cursor or struct, and
## anything else is a term.

import Analysis from "std/analysis"
import Codecs from "codecs"
import Names from "names"
import Types from "types"

## The Lists, Maps, Optionals and Results of a block: `read` those the parameters and the read structs and enums reach, `made` those the
## results and the made ones reach, each after the ones it holds.
struct Shelf
  codecs: Codecs.Plan
  read: List[Types.Type]
  made: List[Types.Type]
end

## The Lists, Maps, Optionals and Results of `block`.
def of(block: Analysis.NativeBlock, codecs: Codecs.Plan) -> Shelf
  read: List[String] = []
  made: List[String] = []
  for function in block.functions
    for param in function.parameters
      read = read.push(param.type)
    end

    made = made.push(function.result)
  end

  for type in block.types
    held = type.members.flat_map do |member: Analysis.NativeMember| member.types end
    if codecs.read.include?(type.name)
      read = read.concat(held)
    end

    if codecs.made.include?(type.name)
      made = made.concat(held)
    end
  end

  Shelf(codecs: codecs, read: collections(read), made: collections(made))
end

## Whether a parameter of `type` arrives as a cursor (a List or Map) or a C struct (an Optional or Result).
def typed?(type: String) -> Bool = held?(Types.parse(type))

## The C type of a parameter of `type`: its cursor or struct, or what the codecs give.
def c_type(shelf: Shelf, type: String) -> String
  return name(shelf, Types.parse(type)) if typed?(type)

  Codecs.c_type(shelf.codecs, "", type)
end

## The C names the Lists, Maps, Optionals and Results declare.
def global_names(shelf: Shelf) -> List[Names.Named]
  named: List[Names.Named] = []
  for type in shelf.read
    c = name(shelf, type)
    source = Types.text(type)
    named = named.concat([
      Names.Named(c: c, source: source),
      Names.Named(c: reader(shelf, type), source: "the decoder of #{source}"),
    ])

    if collection?(type)
      named = named.concat([
        Names.Named(c: "#{c}_open", source: "the open of #{source}"),
        Names.Named(c: "#{c}_next", source: "the next of #{source}"),
      ])
    else
      named = named.push(Names.Named(c: "#{c}_get", source: "the get of #{source}"))
    end
  end

  for held in held_items(shelf)
    c = "#{shelf.codecs.lower}_native_item_#{Types.mangled(held)}"
    named = named.push(Names.Named(c: c, source: "the item decoder of #{Types.text(held)}"))
  end

  for type in shelf.made
    c = name(shelf, type)
    source = Types.text(type)
    if !collection?(type)
      named = named.push(Names.Named(c: "#{c}_#{maker(type)}", source: "the #{maker(type)} of #{source}"))
      next
    end

    named = named.concat([
      Names.Named(c: "#{c}_builder", source: "the builder of #{source}"),
      Names.Named(c: "#{c}_begin", source: "the begin of #{source}"),
      Names.Named(c: "#{c}_#{adder(type)}", source: "the #{adder(type)} of #{source}"),
      Names.Named(c: "#{c}_end", source: "the end of #{source}"),
    ])
  end

  named
end

## The cursor and builder types and the prototypes of their functions.
def declarations(shelf: Shelf) -> List[String]
  return [] if shelf.read.empty? and shelf.made.empty?

  lines = [
    "",
    "/* The Lists, Maps, Optionals and Results. A List or Map that is read is a cursor: _next gives 1 for an item, 0 at",
    "   the end, and -1 when the item does not decode: the call has then failed with the path of the item in its own",
    "   List or Map (an item of a List or Map read from another has the path from the inner one, `List[Float].1`),",
    "   after `argument N: ` when the cursor came from an argument (`argument` is then N; it is 0 after _open), and",
    "   every later _next gives -1 too, as after a failed _open. A builder makes one: _begin, then _push (_put for a",
    "   Map), then _end. Cursors and builders hold terms: keep them in C locals, for this call only. An Optional or",
    "   Result that is read is a struct, whose value is zero when there is none and whose error is borrowed as a String",
    "   argument is; _get reads one held as a term. One that is made has _some or _ok (an_none and an_error make the",
    "   others). */",
  ]

  for type in shelf.read
    if collection?(type)
      lines = joined([lines, [""], cursor_declaration(shelf, type)])
    else
      lines = joined([lines, [""], struct_declaration(shelf, type)])
    end
  end

  for type in shelf.made
    if collection?(type)
      lines = joined([lines, [""], builder_declaration(shelf, type)])
    else
      lines = lines.concat(["", "#{maker_head(shelf, type)};"])
    end
  end

  lines
end

## The definitions of the cursors and builders, for the implementation part of the header.
def definitions(shelf: Shelf) -> List[String]
  lines: List[String] = []
  done: Set[String] = Set.new([])
  # `read` holds each List or Map after those it holds, so the decoder of an item that is one finds its open defined.
  for type in shelf.read
    for held in items(type)
      if !done.include?(Types.mangled(held))
        done = done.add(Types.mangled(held))
        lines = joined([lines, [""], item_decoder(shelf, held)])
      end
    end

    if collection?(type)
      lines = joined([lines, [""], cursor_definition(shelf, type)])
    else
      lines = joined([lines, [""], struct_definition(shelf, type)])
    end
  end

  for type in shelf.made
    if collection?(type)
      lines = joined([lines, [""], builder_definition(shelf, type)])
    else
      lines = joined([lines, [""], maker_definition(shelf, type)])
    end
  end

  lines
end

## The statements of a wrapper that open or decode argument `at`, a List, Map, Optional or Result, into `local`.
def decode_argument(shelf: Shelf, type: String, local: String, at: Int) -> List[String]
  tree = Types.parse(type)
  lines = [
    "  #{name(shelf, tree)} #{local};",
    "  if (!#{reader(shelf, tree)}(env, argv[#{at}], &#{local}, &fail))",
    "    return ng_fail_argument(env, &fail, \"#{type}\", #{at});",
  ]

  # A cursor reads its items after the wrapper returns, so it keeps the argument for the "argument N:" prefix.
  for path in cursor_paths(tree)
    lines = lines.push("  #{local}#{path}.argument = #{at + 1};")
  end

  lines
end

private

# The Lists, Maps, Optionals and Results inside `types`, each once, each after the ones it holds.
def collections(types: List[String]) -> List[Types.Type]
  seen: Set[String] = Set.new([])
  out: List[Types.Type] = []
  for text in types
    for type in Types.inside_out(Types.parse(text))
      if held?(type) and !seen.include?(Types.text(type))
        seen = seen.add(Types.text(type))
        out = out.push(type)
      end
    end
  end

  out
end

# Whether `type` is a List, Map, Optional or Result.
def held?(type: Types.Type) -> Bool
  case type
    Types.Type.Named(_) -> false
    _ -> true
  end
end

def collection?(type: Types.Type) -> Bool
  case type
    Types.Type.ListOf(_) -> true
    Types.Type.MapOf(_, _) -> true
    _ -> false
  end
end

def name(shelf: Shelf, type: Types.Type) -> String = "#{shelf.codecs.lower}_#{Types.mangled(type)}"

# The static function that opens a List or Map, or decodes an Optional or Result, with the path of a failure.
def reader(shelf: Shelf, type: Types.Type) -> String
  return "#{shelf.codecs.lower}_native_open_#{Types.mangled(type)}" if collection?(type)

  "#{shelf.codecs.lower}_native_get_#{Types.mangled(type)}"
end

# The constructor of an Optional or Result that is made.
def maker(type: Types.Type) -> String
  case type
    Types.Type.OptionalOf(_) -> "some"
    _ -> "ok"
  end
end

def adder(type: Types.Type) -> String
  return "put" if map?(type)

  "push"
end

def map?(type: Types.Type) -> Bool
  case type
    Types.Type.MapOf(_, _) -> true
    _ -> false
  end
end

# The item types of the Lists and Maps that are read, each once.
def held_items(shelf: Shelf) -> List[Types.Type]
  seen: Set[String] = Set.new([])
  out: List[Types.Type] = []
  for type in shelf.read
    for held in items(type)
      if !seen.include?(Types.mangled(held))
        seen = seen.add(Types.mangled(held))
        out = out.push(held)
      end
    end
  end

  out
end

# The item types of a List, the key and value types of a Map, or the value type of an Optional or Result.
def items(type: Types.Type) -> List[Types.Type]
  case type
    Types.Type.ListOf(item) -> [item]
    Types.Type.MapOf(key, value) -> [key, value]
    Types.Type.OptionalOf(item) -> [item]
    Types.Type.ResultOf(item) -> [item]
    _ -> []
  end
end

# The C type of an item that is read: a cursor for a List or Map, a struct for an Optional or Result, else what the
# codecs give.
def item_type(shelf: Shelf, type: Types.Type) -> String
  return name(shelf, type) if held?(type)

  Codecs.c_type(shelf.codecs, "", Types.text(type))
end

# The C type of an item that is made: a C value as in the codecs, or a term (a List or Map made by its builder, an
# Optional or Result by its constructor).
def made_type(shelf: Shelf, type: Types.Type) -> String
  return "an_term" if held?(type)

  Codecs.c_type(shelf.codecs, "", Types.text(type))
end

def cursor_declaration(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  kind = "list"
  outs = "#{item_type(shelf, items(type)[0])} *out"
  if map?(type)
    kind = "map"
    outs = "#{item_type(shelf, items(type)[0])} *key, #{item_type(shelf, items(type)[1])} *value"
  end

  [
    "typedef struct {",
    "  an_term term;",
    "  an_#{kind}_cursor cursor;",
    "  size_t len;",
    "  size_t at;",
    "  bool failed;",
    "  int argument; /* 1 + the index of the argument of the call it was opened for, or 0 (_open) */",
    "} #{c};",
    "bool #{c}_open(an_env *env, an_term t, #{c} *out);",
    "int #{c}_next(an_env *env, #{c} *#{kind}, #{outs});",
  ]
end

def builder_declaration(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  if map?(type)
    key = made_type(shelf, items(type)[0])
    value = made_type(shelf, items(type)[1])
    return [
      "typedef struct {",
      "  an_term map;",
      "} #{c}_builder;",
      "void #{c}_begin(an_env *env, #{c}_builder *b);",
      "void #{c}_put(an_env *env, #{c}_builder *b, #{key} key, #{value} value);",
      "an_term #{c}_end(an_env *env, #{c}_builder *b);",
    ]
  end

  [
    "typedef struct {",
    "  an_list_builder builder;",
    "} #{c}_builder;",
    "void #{c}_begin(an_env *env, #{c}_builder *b, size_t hint);",
    "void #{c}_push(an_env *env, #{c}_builder *b, #{made_type(shelf, items(type)[0])} value);",
    "an_term #{c}_end(an_env *env, #{c}_builder *b);",
  ]
end

# The decoder of one item of type `type`: a List or Map is opened, an Optional or Result decoded into its struct,
# anything else decoded as in the codecs.
def item_decoder(shelf: Shelf, type: Types.Type) -> List[String]
  p = shelf.codecs.lower
  head = "static bool #{p}_native_item_#{Types.mangled(type)}(an_env *env, an_term x, #{item_type(shelf, type)} *out,"
  body = "  return #{Codecs.decode_value(shelf.codecs, Types.text(type), "(*out)")};"
  if held?(type)
    body = "  return #{reader(shelf, type)}(env, x, out, fail);"
  end

  ["#{head} ng_fail *fail) {", body, "}"]
end

# The lines that give the cursors in an item (the pointer `item`) the argument of the cursor it came from, so their own
# items fail with the same "argument N:" prefix; nothing for an item with no cursor in it.
def inherit(type: Types.Type, item: String, cursor: String) -> List[String]
  cursor_paths(type).map do |path| "#{item}->#{member(path)}argument = #{cursor}->argument;" end
end

# `path` without its first dot, ready for `->`: ".value.value" is "value.value.", and "" stays "".
def member(path: String) -> String
  return "" if path.empty?

  "#{path.slice(1, path.length - 1)}."
end

# Where the cursors are in the C value of `type`: "" for a List or Map itself, ".value" (repeated) inside an Optional
# or Result; none in another type, and none inside a cursor, whose items are read later.
def cursor_paths(type: Types.Type) -> List[String]
  return [""] if collection?(type)

  if !held?(type)
    none_found: List[String] = []
    return none_found
  end

  cursor_paths(items(type)[0]).map do |path| ".value#{path}" end
end

def cursor_definition(shelf: Shelf, type: Types.Type) -> List[String]
  p = shelf.codecs.lower
  c = name(shelf, type)
  m = Types.mangled(type)
  text = Types.text(type)
  kind = "list"
  if map?(type)
    kind = "map"
  end

  lines = [
    "static bool #{p}_native_open_#{m}(an_env *env, an_term t, #{c} *out, ng_fail *fail) {",
    "  memset(out, 0, sizeof *out);",
    "  out->term = t;",
    "  if (an_#{kind}_cursor_begin(env, t, &out->cursor, &out->len)) return true;",
    "  out->failed = true;",
    "  return ng_expected(fail, \"#{text}\");",
    "}",
    "",
    "bool #{c}_open(an_env *env, an_term t, #{c} *out) {",
    "  ng_fail fail;",
    "  return #{p}_native_open_#{m}(env, t, out, &fail) || ng_raise(env, \"\", \"#{text}\", &fail);",
    "}",
    "",
  ]

  item = "#{p}_native_item_#{Types.mangled(items(type)[0])}"
  if !map?(type)
    taken = "#{item}(env, x, out, &fail)"
    return joined([
      lines,
      [
        "int #{c}_next(an_env *env, #{c} *list, #{item_type(shelf, items(type)[0])} *out) {",
        "  an_term x;",
        "  ng_fail fail;",
        "  size_t at = list->at;",
        "  if (list->failed) return -1;",
        "  if (!an_list_next(env, &list->cursor, &x)) return 0;",
        "  list->at++;",
      ],
      took(taken, "  ", inherit(items(type)[0], "out", "list")),
      [
        "  list->failed = true;",
        "  return ng_fail_cursor_item(env, &fail, \"#{text}\", list->argument, at, NULL);",
        "}",
      ],
    ])
  end

  value = "#{p}_native_item_#{Types.mangled(items(type)[1])}"
  outs = "#{item_type(shelf, items(type)[0])} *key, #{item_type(shelf, items(type)[1])} *value"
  inherited = inherit(items(type)[0], "key", "map").concat(inherit(items(type)[1], "value", "map"))
  joined([
    lines,
    [
      "int #{c}_next(an_env *env, #{c} *map, #{outs}) {",
      "  an_term k, v;",
      "  ng_fail fail;",
      "  size_t at = map->at;",
      "  const char *part = \"key\";",
      "  if (map->failed) return -1;",
      "  if (!an_map_next(env, &map->cursor, &k, &v)) return 0;",
      "  map->at++;",
      "  if (#{item}(env, k, key, &fail)) {",
    ],
    took("#{value}(env, v, value, &fail)", "    ", inherited),
    [
      "    part = \"value\";",
      "  }",
      "  map->failed = true;",
      "  return ng_fail_cursor_item(env, &fail, \"#{text}\", map->argument, at, part);",
      "}",
    ],
  ])
end

# `if (TAKEN) return 1;` at `indent`, with the `inherited` lines run first when there are any.
def took(taken: String, indent: String, inherited: List[String]) -> List[String]
  return ["#{indent}if (#{taken}) return 1;"] if inherited.empty?

  body = inherited.map do |line| "#{indent}  #{line}" end
  joined([["#{indent}if (#{taken}) {"], body, ["#{indent}  return 1;", "#{indent}}"]])
end

def builder_definition(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  if map?(type)
    key = items(type)[0]
    value = items(type)[1]
    return [
      "void #{c}_begin(an_env *env, #{c}_builder *b) { b->map = an_map_from(env, NULL, NULL, 0); }",
      "",
      "void #{c}_put(an_env *env, #{c}_builder *b, #{made_type(shelf, key)} key, #{made_type(shelf, value)} value) {",
      "  b->map = an_map_put(env, b->map, #{made(shelf, key, "key")}, #{made(shelf, value, "value")});",
      "}",
      "",
      "an_term #{c}_end(an_env *env, #{c}_builder *b) {",
      "  (void)env;",
      "  return b->map;",
      "}",
    ]
  end

  item = items(type)[0]
  [
    "void #{c}_begin(an_env *env, #{c}_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }",
    "",
    "void #{c}_push(an_env *env, #{c}_builder *b, #{made_type(shelf, item)} value) {",
    "  an_list_push(env, &b->builder, #{made(shelf, item, "value")});",
    "}",
    "",
    "an_term #{c}_end(an_env *env, #{c}_builder *b) { return an_list_end(env, &b->builder); }",
  ]
end

# The struct of an Optional (`some`, `value`) or a Result (`ok`, `value`, `error`) that is read.
def struct_declaration(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  value = "  #{item_type(shelf, items(type)[0])} value;"
  getter = "bool #{c}_get(an_env *env, an_term t, #{c} *out);"
  return ["typedef struct {", "  bool some;", value, "} #{c};", getter] if maker(type) == "some"

  ["typedef struct {", "  bool ok;", value, "  ng_str error;", "} #{c};", getter]
end

# The decoder of an Optional or Result into its struct: the value is decoded only when there is one, and the error of a
# Result is its message.
def struct_definition(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  text = Types.text(type)
  item = "#{shelf.codecs.lower}_native_item_#{Types.mangled(items(type)[0])}"
  lines = [
    "static bool #{reader(shelf, type)}(an_env *env, an_term x, #{c} *out, ng_fail *fail) {",
    "  an_term v;",
    "  memset(out, 0, sizeof *out);",
  ]

  if maker(type) == "some"
    return (
      lines.concat([
        "  if (!an_get_optional(env, x, &out->some, &v)) return ng_expected(fail, \"#{text}\");",
        "  return !out->some || #{item}(env, v, &out->value, fail) || ng_at(fail, \"some\");",
        "}",
      ])
        .concat(public_get(shelf, type))
    )
  end

  (
    lines.concat([
      "  if (!an_get_result(env, x, &out->ok, &v)) return ng_expected(fail, \"#{text}\");",
      "  if (!out->ok)",
      "    return an_get_string(env, v, &out->error.data, &out->error.len) || ng_leaf(fail, \"String\", \"error\");",
      "  return #{item}(env, v, &out->value, fail) || ng_at(fail, \"ok\");",
      "}",
    ])
      .concat(public_get(shelf, type))
  )
end

# `_get`, which reads an Optional or Result that the C code holds as a term, such as a field of a struct.
def public_get(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  [
    "",
    "bool #{c}_get(an_env *env, an_term t, #{c} *out) {",
    "  ng_fail fail;",
    "  return #{reader(shelf, type)}(env, t, out, &fail) || ng_raise(env, \"\", \"#{Types.text(type)}\", &fail);",
    "}",
  ]
end

def maker_head(shelf: Shelf, type: Types.Type) -> String
  value = made_type(shelf, items(type)[0])
  "an_term #{name(shelf, type)}_#{maker(type)}(an_env *env, #{value} value)"
end

def maker_definition(shelf: Shelf, type: Types.Type) -> List[String]
  ["#{maker_head(shelf, type)} {", "  return an_#{maker(type)}(env, #{made(shelf, items(type)[0], "value")});", "}"]
end

# The term of the item `source` of `type`.
def made(shelf: Shelf, type: Types.Type, source: String) -> String
  return source if held?(type)

  Codecs.encoded(shelf.codecs, "", Types.text(type), source)
end

def joined(parts: List[List[String]]) -> List[String] = parts.flat_map do |part: List[String]| part end

## The typed Lists and Maps of a block (pure). A List or Map that a parameter reaches is read lazily through a cursor:
## `_open` and `_next`, which gives 1 for an item, 0 at the end and -1 for a bad item (the call has then failed with
## its path, `List[Point].2.x: expected Int`), and never copies to an array. One that a result reaches is made with a
## builder: `_begin`, `_push` (`_put` for a Map) and `_end`. An item is a C value as in the codecs, a List or Map that
## is read is its cursor, and anything else is a term.

import Analysis from "std/analysis"
import Codecs from "codecs"
import Names from "names"
import Types from "types"

## The Lists and Maps of a block: `read` those the parameters and the read structs and enums reach, `made` those the
## results and the made ones reach, each after the ones it holds.
export struct Shelf
  codecs: Codecs.Plan
  read: List[Types.Type]
  made: List[Types.Type]
end

## The Lists and Maps of `block`.
export def of(block: Analysis.NativeBlock, codecs: Codecs.Plan) -> Shelf
  read: List[String] = []
  made: List[String] = []
  for function in block.functions
    for param in function.parameters
      read = read.concat([param.type])
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

  return Shelf(codecs: codecs, read: collections(read), made: collections(made))
end

## Whether a parameter of `type` arrives as a cursor.
export def cursor?(shelf: Shelf, type: String) -> Bool
  return collection?(Types.parse(type))
end

## The C type of a parameter of `type`: its cursor, or what the codecs give.
export def c_type(shelf: Shelf, type: String) -> String
  if cursor?(shelf, type)
    return name(shelf, Types.parse(type))
  end

  return Codecs.c_type(shelf.codecs, "", type)
end

## The C names the Lists and Maps declare.
export def global_names(shelf: Shelf) -> List[Names.Named]
  named: List[Names.Named] = []
  for type in shelf.read
    c = name(shelf, type)
    source = Types.text(type)
    named = named.concat([
      Names.Named(c: c, source: source),
      Names.Named(c: "#{c}_open", source: "the open of #{source}"),
      Names.Named(c: "#{c}_next", source: "the next of #{source}"),
      Names.Named(c: "#{shelf.codecs.lower}_native_open_#{Types.mangled(type)}", source: "the decoder of #{source}"),
    ])
  end

  for type in shelf.made
    c = name(shelf, type)
    source = Types.text(type)
    named = named.concat([
      Names.Named(c: "#{c}_builder", source: "the builder of #{source}"),
      Names.Named(c: "#{c}_begin", source: "the begin of #{source}"),
      Names.Named(c: "#{c}_#{adder(type)}", source: "the #{adder(type)} of #{source}"),
      Names.Named(c: "#{c}_end", source: "the end of #{source}"),
    ])
  end

  return named
end

## The cursor and builder types and the prototypes of their functions.
export def declarations(shelf: Shelf) -> List[String]
  if shelf.read.empty? and shelf.made.empty?
    return []
  end

  lines = [
    "",
    "/* The Lists and Maps. _next gives 1 for an item, 0 at the end, and -1 when the item does not decode, and then the",
    "   call has failed with its path. A builder makes one: _begin, then _push (_put for a Map), then _end. */",
  ]

  for type in shelf.read
    lines = joined([lines, [""], cursor_declaration(shelf, type)])
  end

  for type in shelf.made
    lines = joined([lines, [""], builder_declaration(shelf, type)])
  end

  return lines
end

## The definitions of the cursors and builders, for the implementation part of the header.
export def definitions(shelf: Shelf) -> List[String]
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

    lines = joined([lines, [""], cursor_definition(shelf, type)])
  end

  for type in shelf.made
    lines = joined([lines, [""], builder_definition(shelf, type)])
  end

  return lines
end

## The statements of a wrapper that open argument `at`, a List or Map, into `local`.
export def decode_argument(shelf: Shelf, type: String, local: String, at: Int) -> List[String]
  tree = Types.parse(type)
  opener = "#{shelf.codecs.lower}_native_open_#{Types.mangled(tree)}"
  return [
    "  #{name(shelf, tree)} #{local};",
    "  if (!#{opener}(env, argv[#{at}], &#{local}, &fail)) return ng_fail_argument(env, &fail, \"#{type}\", #{at});",
  ]
end

# The Lists and Maps inside `types`, each once, each after the ones it holds.
def collections(types: List[String]) -> List[Types.Type]
  seen: Set[String] = Set.new([])
  out: List[Types.Type] = []
  for text in types
    for type in Types.inside_out(Types.parse(text))
      if collection?(type) and !seen.include?(Types.text(type))
        seen = seen.add(Types.text(type))
        out = out.push(type)
      end
    end
  end

  return out
end

def collection?(type: Types.Type) -> Bool
  case type
    Types.Type.ListOf(_) -> return true
    Types.Type.MapOf(_, _) -> return true
    _ -> return false
  end
end

def name(shelf: Shelf, type: Types.Type) -> String
  return "#{shelf.codecs.lower}_#{Types.mangled(type)}"
end

def adder(type: Types.Type) -> String
  if map?(type)
    return "put"
  end

  return "push"
end

def map?(type: Types.Type) -> Bool
  case type
    Types.Type.MapOf(_, _) -> return true
    _ -> return false
  end
end

# The item types of a List, or the key and value types of a Map.
def items(type: Types.Type) -> List[Types.Type]
  case type
    Types.Type.ListOf(item) -> return [item]
    Types.Type.MapOf(key, value) -> return [key, value]
    _ -> return []
  end
end

# The C type of an item that is read: a cursor for a List or Map, else what the codecs give.
def item_type(shelf: Shelf, type: Types.Type) -> String
  if collection?(type)
    return name(shelf, type)
  end

  return Codecs.c_type(shelf.codecs, "", Types.text(type))
end

# The C type of an item that is made: a C value as in the codecs, or a term (a List or Map made by its builder).
def made_type(shelf: Shelf, type: Types.Type) -> String
  if collection?(type)
    return "an_term"
  end

  return Codecs.c_type(shelf.codecs, "", Types.text(type))
end

def cursor_declaration(shelf: Shelf, type: Types.Type) -> List[String]
  c = name(shelf, type)
  kind = "list"
  outs = "#{item_type(shelf, items(type)[0])} *out"
  if map?(type)
    kind = "map"
    outs = "#{item_type(shelf, items(type)[0])} *key, #{item_type(shelf, items(type)[1])} *value"
  end

  return [
    "typedef struct {",
    "  an_term term;",
    "  an_#{kind}_cursor cursor;",
    "  size_t len;",
    "  size_t at;",
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

  return [
    "typedef struct {",
    "  an_list_builder builder;",
    "} #{c}_builder;",
    "void #{c}_begin(an_env *env, #{c}_builder *b, size_t hint);",
    "void #{c}_push(an_env *env, #{c}_builder *b, #{made_type(shelf, items(type)[0])} value);",
    "an_term #{c}_end(an_env *env, #{c}_builder *b);",
  ]
end

# The decoder of one item of type `type`: a List or Map is opened, anything else decoded as in the codecs.
def item_decoder(shelf: Shelf, type: Types.Type) -> List[String]
  p = shelf.codecs.lower
  head = "static bool #{p}_native_item_#{Types.mangled(type)}(an_env *env, an_term x, #{item_type(shelf, type)} *out,"
  body = "  return #{Codecs.decode_value(shelf.codecs, Types.text(type), "(*out)")};"
  if collection?(type)
    body = "  return #{p}_native_open_#{Types.mangled(type)}(env, x, out, fail);"
  end

  return ["#{head} ng_fail *fail) {", body, "}"]
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
    "  out->term = t;",
    "  out->at = 0;",
    "  return an_#{kind}_cursor_begin(env, t, &out->cursor, &out->len) || ng_expected(fail, \"#{text}\");",
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
    return lines.concat([
      "int #{c}_next(an_env *env, #{c} *list, #{item_type(shelf, items(type)[0])} *out) {",
      "  an_term x;",
      "  ng_fail fail;",
      "  if (!an_list_next(env, &list->cursor, &x)) return 0;",
      "  if (!#{item}(env, x, out, &fail)) return ng_fail_item(env, &fail, \"#{text}\", list->at, NULL);",
      "  list->at++;",
      "  return 1;",
      "}",
    ])
  end

  value = "#{p}_native_item_#{Types.mangled(items(type)[1])}"
  outs = "#{item_type(shelf, items(type)[0])} *key, #{item_type(shelf, items(type)[1])} *value"
  return lines.concat([
    "int #{c}_next(an_env *env, #{c} *map, #{outs}) {",
    "  an_term k, v;",
    "  ng_fail fail;",
    "  if (!an_map_next(env, &map->cursor, &k, &v)) return 0;",
    "  if (!#{item}(env, k, key, &fail)) return ng_fail_item(env, &fail, \"#{text}\", map->at, \"key\");",
    "  if (!#{value}(env, v, value, &fail)) return ng_fail_item(env, &fail, \"#{text}\", map->at, \"value\");",
    "  map->at++;",
    "  return 1;",
    "}",
  ])
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
  return [
    "void #{c}_begin(an_env *env, #{c}_builder *b, size_t hint) { an_list_begin(env, &b->builder, hint); }",
    "",
    "void #{c}_push(an_env *env, #{c}_builder *b, #{made_type(shelf, item)} value) {",
    "  an_list_push(env, &b->builder, #{made(shelf, item, "value")});",
    "}",
    "",
    "an_term #{c}_end(an_env *env, #{c}_builder *b) { return an_list_end(env, &b->builder); }",
  ]
end

# The term of the item `source` of `type`.
def made(shelf: Shelf, type: Types.Type, source: String) -> String
  if collection?(type)
    return source
  end

  return Codecs.encoded(shelf.codecs, "", Types.text(type), source)
end

def joined(parts: List[List[String]]) -> List[String]
  return parts.flat_map do |part: List[String]| part end
end

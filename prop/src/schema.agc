## `Prop.of`: a generator for a struct or enum that JSON can decode, built from its JSON Schema.

import Gens from "gen"

# The most items a generated list holds.
LIST_MAX = 3
# The longest key of a generated map.
KEY_MAX = 4
# The keys of the maps of an exhaustive check: a map holds each key or leaves it out, so two cases are never the same
# map (a list of pairs would repeat the maps whose keys collide).
KEYS = ["a", "b", "é 漢"]
# A recursive type that cannot end (a required field of its own type) goes deeper than any real depth; stop there.
LOWEST = -8

# The members of a schema's `properties`, read only for their names: a `Json` has no keys, so a map of structs (with no
# fields that matter) is the way to list them.
struct Member
  type: Optional[String] = none
end

struct Properties
  properties: Map[String, Member]
end

## A generator of `T` from `codec` and `schema`: pass `T.codec` and `JSON.schema(T)` of the same struct or enum. The
## generator makes the JSON of a value that the schema allows (Int, Float, String, Bool, lists, maps, `Optional`s,
## nested structs and enums) and decodes it, so it makes only values `T` can have, and it shrinks as its parts do (an
## Optional to `none`, a list to fewer items). A type that holds itself, through a list, a map, an Optional or a
## variant, nests at most `depth` times. Halts when the schema is not the one of `T`.
export def of[T](codec: Codec[T], schema: Json, depth: Int = 2) -> Gens.Gen[T]
  return Gens.map(build(schema, schema, [], depth)) do |document| decoded(codec, document) end
end

def decoded[T](codec: Codec[T], document: Json) -> T
  # A document the schema allowed always decodes; a failure means the schema belongs to another type.
  return codec.decode(document).unwrap!
end

def build(node: Json, root: Json, path: List[String], depth: Int) -> Gens.Gen[Json]
  if depth < LOWEST
    return unsupported(node, "a recursive type needs an Optional, a list, a map or a variant that ends it")
  end

  if has?(node, "$ref")
    return follow(node, root, path, depth)
  elsif has?(node, "enum")
    return Gens.one_of(items(node, "enum"))
  elsif has?(node, "anyOf")
    return Gens.choose(branches(items(node, "anyOf"), root, path, depth, true))
  elsif has?(node, "oneOf")
    return Gens.choose(branches(items(node, "oneOf"), root, path, depth, false))
  end

  return typed(node, root, path, depth)
end

def typed(node: Json, root: Json, path: List[String], depth: Int) -> Gens.Gen[Json]
  case text(node, "type")
    "integer" -> return Gens.map(Gens.int(-1000, 1000)) do |n| JSON.from(n) end
    "number" -> return Gens.map(Gens.float(-1000.0, 1000.0)) do |x| JSON.from(x) end
    "string" -> return Gens.map(Gens.string()) do |s| JSON.from(s) end
    "boolean" -> return Gens.map(Gens.bool()) do |b| JSON.from(b) end
    "null" -> return Gens.just(JSON.null())
    "array" -> return array(node, root, path, depth)
    "object" -> return object(node, root, path, depth)
    _ -> return unsupported(node, "its type is not one of a decodable struct or enum")
  end
end

# A `$ref` is `#/$defs/Name`. Reaching a name again inside itself is a recursion, and only that uses up `depth`.
def follow(node: Json, root: Json, path: List[String], depth: Int) -> Gens.Gen[Json]
  name = text(node, "$ref").split("/").last
  target = lookup(root, name)
  if target.none?
    return unsupported(node, "it refers to #{name}, which is not in $defs")
  end

  if path.include?(name)
    return build(target.unwrap!, root, path, depth - 1)
  end

  return build(target.unwrap!, root, path.push(name), depth)
end

# The null branch of an Optional goes first, so it is the simplest case. When `depth` is used up, a branch that
# refers to another type is left out, if any other is left: that is what lets a recursive variant end.
def branches(
  nodes: List[Json],
  root: Json,
  path: List[String],
  depth: Int,
  simplest_null: Bool,
) -> List[Gens.Gen[Json]]
  usable = nodes
  if depth <= 0
    ends = nodes.select do |node| not JSON.encode(node).include?("$ref") end
    if not ends.empty?
      usable = ends
    end
  end

  ordered = usable
  if simplest_null
    nulls = usable.select do |node| text(node, "type") == "null" end
    ordered = nulls.concat(usable.select do |node| text(node, "type") != "null" end)
  end

  return ordered.map do |node| build(node, root, path, depth) end
end

# Tuples (`prefixItems`, the payload of a variant) have one gen per place; a list has one for all its items.
def array(node: Json, root: Json, path: List[String], depth: Int) -> Gens.Gen[Json]
  if has?(node, "prefixItems")
    places = items(node, "prefixItems").map do |place| build(place, root, path, depth) end
    return Gens.map(Gens.sequence(places)) do |values| JSON.array(values) end
  end

  element = field(node, "items")
  if element.none? or depth <= 0
    return Gens.just(JSON.array([]))
  end

  return Gens.map(Gens.list(build(element.unwrap!, root, path, depth), LIST_MAX)) do |values| JSON.array(values) end
end

# A struct has `properties`; a map has `additionalProperties`. All the properties are made, the optional ones too.
def object(node: Json, root: Json, path: List[String], depth: Int) -> Gens.Gen[Json]
  if has?(node, "properties")
    names = JSON.decode(node, Properties).unwrap!.properties.keys
    values = names.map do |name| build(member(node, name), root, path, depth) end
    return Gens.map(Gens.sequence(values)) do |made| record(names, made) end
  end

  extra = field(node, "additionalProperties")
  if extra.none? or depth <= 0
    return Gens.just(record([], []))
  end

  return dictionaries(build(extra.unwrap!, root, path, depth))
end

def record(names: List[String], values: List[Json]) -> Json
  fields: Map[String, Json] = {}
  for i in 0...names.size
    fields = fields.put(names.at(i), values.at(i))
  end

  return JSON.object(fields)
end

# A map of `value`s. `check` draws random keys (pairs that shrink away one by one); `exhaustive` goes over the maps of
# the fixed KEYS, which are all different.
def dictionaries(value: Gens.Gen[Json]) -> Gens.Gen[Json]
  drawn = Gens.map(Gens.list(Gens.pair(Gens.string(KEY_MAX), value), LIST_MAX)) do |pairs| from_pairs(pairs) end
  slots = KEYS.map do |_| Gens.optional(value) end
  listed = Gens.map(Gens.sequence(slots)) do |made| from_slots(made) end
  return Gens.Gen(make: drawn.make, count: listed.count, all: listed.all)
end

def from_pairs(pairs: List[Gens.Pair[String, Json]]) -> Json
  fields: Map[String, Json] = {}
  for entry in pairs
    fields = fields.put(entry.first, entry.second)
  end

  return JSON.object(fields)
end

def from_slots(made: List[Optional[Json]]) -> Json
  fields: Map[String, Json] = {}
  for i in 0...KEYS.size
    if made.at(i).some?
      fields = fields.put(KEYS.at(i), made.at(i).unwrap!)
    end
  end

  return JSON.object(fields)
end

# A schema this package did not write: the type is not decodable, or the schema is not the one of the codec.
def unsupported(node: Json, why: String) -> Gens.Gen[Json]
  bad: Result[Gens.Gen[Json]] = error("Prop.of: cannot make #{JSON.encode(node)}: #{why}")
  return bad.unwrap!
end

def field(node: Json, key: String) -> Optional[Json]
  found = JSON.get(node, key)
  if found.ok?
    return some(found.unwrap!)
  end

  return none
end

def has?(node: Json, key: String) -> Bool
  return JSON.get(node, key).ok?
end

# The string at `key`, or "" (a schema with no `type` is not a type this package makes).
def text(node: Json, key: String) -> String
  found = field(node, key)
  if found.none?
    return ""
  end

  return JSON.string(found.unwrap!).unwrap_or("")
end

def items(node: Json, key: String) -> List[Json]
  none_found: List[Json] = []
  found = field(node, key)
  if found.none?
    return none_found
  end

  return JSON.list(found.unwrap!).unwrap_or(none_found)
end

def member(node: Json, name: String) -> Json
  return JSON.get(JSON.get(node, "properties").unwrap!, name).unwrap!
end

def lookup(root: Json, name: String) -> Optional[Json]
  defs = field(root, "$defs")
  if defs.none?
    return none
  end

  return field(defs.unwrap!, name)
end

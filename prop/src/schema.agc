## `Prop.of`: a generator for a struct or enum that JSON can decode, built from its JSON Schema.

import Gens from "gen"

## A generator of `T` from `codec` and `schema`: pass `T.codec` and `JSON.schema(T)` of the same struct or enum. The
## generator makes the JSON of a value that the schema allows (Int, Float, String, Bool, lists, maps, `Optional`s,
## nested structs and enums) and decodes it, so it makes only values `T` can have, and it shrinks as its parts do (an
## Optional to `none`, a list to fewer items). A type that holds itself, through a list, a map, an Optional or a
## variant, nests at most `depth` times. Halts when the schema is not the one of `T`.
##
## ```ruby
## Prop.sample(Prop.of(User.codec, JSON.schema(User)), 1, 2) # User has name: String and age: Int
## # [User(name: "mdRY", age: 423), User(name: "TeL%;yAb+", age: -973)]
## ```
def of[T](codec: Codec[T], schema: JSON.Value, depth: Int = 2) -> Gens.Gen[T]
  Gens.map(build(schema, schema, [], depth)) do |document| decoded(codec, document) end
end

private

# The most items a generated list holds.
LIST_MAX = 3
# The longest key of a generated map.
KEY_MAX = 4
# The keys of the maps of an exhaustive check: a map holds each key or leaves it out, so two cases are never the same
# map (a list of pairs would repeat the maps whose keys collide).
KEYS = ["a", "b", "é 漢"]
# A recursive type that cannot end (a required field of its own type) goes deeper than any real depth; stop there.
LOWEST = -8

# The members of a schema's `properties`, read only for their names: a `JSON.Value` has no keys, so a map of structs
# (with no fields that matter) is the way to list them.
struct Member
  type: Optional[String] = none
end

struct Properties
  properties: Map[String, Member]
end

def decoded[T](codec: Codec[T], document: JSON.Value) -> T
  # A document the schema allowed always decodes; a failure means the schema belongs to another type.
  codec.decode(document).unwrap!
end

def build(node: JSON.Value, root: JSON.Value, path: List[String], depth: Int) -> Gens.Gen[JSON.Value]
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

  typed(node, root, path, depth)
end

def typed(node: JSON.Value, root: JSON.Value, path: List[String], depth: Int) -> Gens.Gen[JSON.Value]
  case text(node, "type")
    "integer" -> Gens.map(Gens.int(-1000, 1000)) do |n| JSON.from(n) end
    "number" -> Gens.map(Gens.float(-1000.0, 1000.0)) do |x| JSON.from(x) end
    "string" -> Gens.map(Gens.string()) do |s| JSON.from(s) end
    "boolean" -> Gens.map(Gens.bool()) do |b| JSON.from(b) end
    "null" -> Gens.just(JSON.null())
    "array" -> array(node, root, path, depth)
    "object" -> object(node, root, path, depth)
    _ -> unsupported(node, "its type is not one of a decodable struct or enum")
  end
end

# A `$ref` is `#/$defs/Name`. Reaching a name again inside itself is a recursion, and only that uses up `depth`.
def follow(node: JSON.Value, root: JSON.Value, path: List[String], depth: Int) -> Gens.Gen[JSON.Value]
  name = text(node, "$ref").split("/").last
  target = lookup(root, name)
  return unsupported(node, "it refers to #{name}, which is not in $defs") if target.none?

  return build(target.unwrap!, root, path, depth - 1) if path.include?(name)

  build(target.unwrap!, root, path.push(name), depth)
end

# The null branch of an Optional goes first, so it is the simplest case. When `depth` is used up, a branch that
# refers to another type is left out, if any other is left: that is what lets a recursive variant end.
def branches(
  nodes: List[JSON.Value],
  root: JSON.Value,
  path: List[String],
  depth: Int,
  simplest_null: Bool,
) -> List[Gens.Gen[JSON.Value]]
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

  ordered.map do |node| build(node, root, path, depth) end
end

# Tuples (`prefixItems`, the payload of a variant) have one gen per place; a list has one for all its items.
def array(node: JSON.Value, root: JSON.Value, path: List[String], depth: Int) -> Gens.Gen[JSON.Value]
  if has?(node, "prefixItems")
    places = items(node, "prefixItems").map do |place| build(place, root, path, depth) end
    return Gens.map(Gens.sequence(places)) do |values| JSON.array(values) end
  end

  element = field(node, "items")
  return Gens.just(JSON.array([])) if element.none? or depth <= 0

  Gens.map(Gens.list(build(element.unwrap!, root, path, depth), LIST_MAX)) do |values| JSON.array(values) end
end

# A struct has `properties`; a map has `additionalProperties`. All the properties are made, the optional ones too.
def object(node: JSON.Value, root: JSON.Value, path: List[String], depth: Int) -> Gens.Gen[JSON.Value]
  if has?(node, "properties")
    names = JSON.decode(node, Properties).unwrap!.properties.keys
    values = names.map do |name| build(member(node, name), root, path, depth) end
    return Gens.map(Gens.sequence(values)) do |made| record(names, made) end
  end

  extra = field(node, "additionalProperties")
  return Gens.just(record([], [])) if extra.none? or depth <= 0

  dictionaries(build(extra.unwrap!, root, path, depth))
end

def record(names: List[String], values: List[JSON.Value]) -> JSON.Value
  fields: Map[String, JSON.Value] = {}
  for i in 0...names.size
    fields = fields.put(names.at(i), values.at(i))
  end

  JSON.object(fields)
end

# A map of `value`s. `check` draws random keys (pairs that shrink away one by one); `exhaustive` goes over the maps of
# the fixed KEYS, which are all different.
def dictionaries(value: Gens.Gen[JSON.Value]) -> Gens.Gen[JSON.Value]
  drawn = Gens.map(Gens.list(Gens.pair(Gens.string(KEY_MAX), value), LIST_MAX)) do |pairs| from_pairs(pairs) end
  slots = KEYS.map do |_| Gens.optional(value) end
  listed = Gens.map(Gens.sequence(slots)) do |made| from_slots(made) end
  Gens.Gen(make: drawn.make, count: listed.count, all: listed.all, show: listed.show)
end

def from_pairs(pairs: List[Gens.Pair[String, JSON.Value]]) -> JSON.Value
  fields: Map[String, JSON.Value] = {}
  for entry in pairs
    fields = fields.put(entry.first, entry.second)
  end

  JSON.object(fields)
end

def from_slots(made: List[Optional[JSON.Value]]) -> JSON.Value
  fields: Map[String, JSON.Value] = {}
  for i in 0...KEYS.size
    if made.at(i).some?
      fields = fields.put(KEYS.at(i), made.at(i).unwrap!)
    end
  end

  JSON.object(fields)
end

# A schema this package did not write: the type is not decodable, or the schema is not the one of the codec.
def unsupported(node: JSON.Value, why: String) -> Gens.Gen[JSON.Value]
  bad: Result[Gens.Gen[JSON.Value]] = error("Prop.of: cannot make #{JSON.encode(node)}: #{why}")
  bad.unwrap!
end

def field(node: JSON.Value, key: String) -> Optional[JSON.Value]
  found = JSON.get(node, key)
  return some(found.unwrap!) if found.ok?

  none
end

def has?(node: JSON.Value, key: String) -> Bool = JSON.get(node, key).ok?

# The string at `key`, or "" (a schema with no `type` is not a type this package makes).
def text(node: JSON.Value, key: String) -> String
  found = field(node, key)
  return "" if found.none?

  JSON.string(found.unwrap!).unwrap_or("")
end

def items(node: JSON.Value, key: String) -> List[JSON.Value]
  none_found: List[JSON.Value] = []
  found = field(node, key)
  return none_found if found.none?

  JSON.list(found.unwrap!).unwrap_or(none_found)
end

def member(node: JSON.Value, name: String) -> JSON.Value = JSON.get(JSON.get(node, "properties").unwrap!, name).unwrap!

def lookup(root: JSON.Value, name: String) -> Optional[JSON.Value]
  defs = field(root, "$defs")
  return none if defs.none?

  field(defs.unwrap!, name)
end

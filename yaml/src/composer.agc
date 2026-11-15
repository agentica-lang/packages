## The composer: the tree of each document to its JSON value. It resolves the scalars by the core schema, checks the
## tags of the collections, refuses a key that is not a string and a key given twice, and replaces each alias by the
## value of its anchor, counting the nodes and the bytes that aliases add, and the depth they reach, so that a few
## lines cannot stand for a huge or a deep document.

import Schema from "schema"
import Source from "source"
import Types from "types"

def documents(src: Source.Source, nodes: List[Types.Node]) -> Result[List[JSON.Value]]
  values: List[JSON.Value] = []
  state = State(anchors: {}, alias_nodes: 0, alias_bytes: 0)
  for node in nodes
    built = try compose(src, node, state.with(anchors: {}))
    values = values.push(built.value)
    state = built.state
  end

  ok(values)
end

private

# How much a value stands for: its nodes, the bytes of its scalars and keys, and its nested collections.
struct Weight
  nodes: Int
  bytes: Int
  height: Int
end

struct Anchored
  value: JSON.Value
  weight: Weight
end

struct State
  anchors: Map[String, Anchored]
  alias_nodes: Int
  alias_bytes: Int
end

struct Built
  value: JSON.Value
  weight: Weight
  state: State
end

def compose(src: Source.Source, node: Types.Node, state: State) -> Result[Built]
  case node
    Types.Node.Alias(name, pos) -> alias(src, name, pos, state)
    Types.Node.Scalar(meta, plain, text) -> scalar(src, meta, plain, text, state)
    Types.Node.Seq(meta, items) -> seq(src, meta, items, state)
    Types.Node.Map(meta, entries) -> map(src, meta, entries, state)
  end
end

def alias(src: Source.Source, name: String, pos: Int, state: State) -> Result[Built]
  case state.anchors.get(name)
    some(anchored) ->
      nodes = state.alias_nodes + anchored.weight.nodes
      bytes = state.alias_bytes + anchored.weight.bytes
      options = src.options
      if nodes > options.max_alias_nodes
        return Source.over_limit(src, pos, "aliases add more than #{options.max_alias_nodes} nodes")
      end

      if bytes > options.max_alias_bytes
        return Source.over_limit(src, pos, "aliases add more than #{options.max_alias_bytes} bytes")
      end

      ok(
        Built(
          value: anchored.value,
          weight: anchored.weight,
          state: state.with(alias_nodes: nodes, alias_bytes: bytes),
        ),
      )
    none -> Source.fail(src, pos, "undefined alias *#{name}")
  end
end

def scalar(src: Source.Source, meta: Types.Meta, plain: Bool, text: String, state: State) -> Result[Built]
  case Schema.scalar(text, plain, meta.tag)
    ok(value) ->
      ok(anchored(meta, Built(value: value, weight: Weight(nodes: 1, bytes: text.bytesize, height: 0), state: state)))
    error(e) -> Source.fail(src, meta.pos, e.message)
  end
end

def seq(src: Source.Source, meta: Types.Meta, items: List[Types.Node], state: State) -> Result[Built]
  return tag_error(src, meta) if not Schema.collection_tag?(meta.tag, "seq")

  values: List[JSON.Value] = []
  weight = Weight(nodes: 1, bytes: 0, height: 1)
  current = state
  for item in items
    built = try compose(src, item, current)
    values = values.push(built.value)
    weight = added(weight, built.weight)
    current = built.state
  end

  collection(src, meta, Built(value: JSON.array(values), weight: weight, state: current))
end

def map(src: Source.Source, meta: Types.Meta, entries: List[Types.Entry], state: State) -> Result[Built]
  return tag_error(src, meta) if not Schema.collection_tag?(meta.tag, "map")

  fields: Map[String, JSON.Value] = {}
  weight = Weight(nodes: 1, bytes: 0, height: 1)
  current = state
  for entry in entries
    key = try compose(src, entry.key, current)
    pos = position(entry.key)
    if JSON.kind(key.value) != "string"
      return Source.fail(src, pos, "a mapping key must be a string, not #{JSON.kind(key.value)} #{key.value}")
    end

    name = JSON.string(key.value).unwrap!
    return Source.fail(src, pos, "duplicate key \"#{name}\"") if fields.key?(name)

    value = try compose(src, entry.value, key.state)
    fields = fields.put(name, value.value)
    weight = added(added(weight, key.weight), value.weight)
    current = value.state
  end

  collection(src, meta, Built(value: JSON.object(fields), weight: weight, state: current))
end

def added(weight: Weight, child: Weight) -> Weight
  Weight(
    nodes: weight.nodes + child.nodes,
    bytes: weight.bytes + child.bytes,
    height: [weight.height, child.height + 1].max.unwrap_or(0),
  )
end

# The parser bounds the nesting of the text; an alias can still nest a deep value in another one.
def collection(src: Source.Source, meta: Types.Meta, built: Built) -> Result[Built]
  limit = src.options.max_depth
  if built.weight.height > limit
    return Source.over_limit(src, meta.pos, "nesting deeper than #{limit} through aliases")
  end

  ok(anchored(meta, built))
end

def anchored(meta: Types.Meta, built: Built) -> Built
  return built if meta.anchor == ""

  anchors = built.state.anchors.put(meta.anchor, Anchored(value: built.value, weight: built.weight))
  built.with(state: built.state.with(anchors: anchors))
end

def tag_error[T](src: Source.Source, meta: Types.Meta) -> Result[T]
  Source.fail(src, meta.pos, "a collection cannot be tagged #{Schema.shown(meta.tag)}")
end

def position(node: Types.Node) -> Int
  case node
    Types.Node.Alias(_, pos) -> pos
    Types.Node.Scalar(meta, _, _) -> meta.pos
    Types.Node.Seq(meta, _) -> meta.pos
    Types.Node.Map(meta, _) -> meta.pos
  end
end

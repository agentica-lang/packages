## The composer: the tree of each document to its JSON value. It resolves the scalars by the core schema, checks the
## tags of the collections, refuses a key that is not a string and a key given twice, and replaces each alias by the
## value of its anchor, counting the nodes that aliases add so that a few lines cannot stand for a huge document.

import Schema from "schema"
import Source from "source"
import Types from "types"

def documents(src: Source.Source, nodes: List[Types.Node]) -> Result[List[JSON.Value]]
  values: List[JSON.Value] = []
  state = State(anchors: {}, alias_nodes: 0)
  for node in nodes
    built = try compose(src, node, state.with(anchors: {}))
    values = values.push(built.value)
    state = built.state
  end

  ok(values)
end

private

struct Anchored
  value: JSON.Value
  size: Int
end

struct State
  anchors: Map[String, Anchored]
  alias_nodes: Int
end

# A composed value, how many nodes it stands for (an alias counts the nodes of its anchor) and the state after it.
struct Built
  value: JSON.Value
  size: Int
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
      total = state.alias_nodes + anchored.size
      limit = src.options.max_alias_nodes
      return Source.over_limit(src, pos, "aliases add more than #{limit} nodes") if total > limit

      ok(Built(value: anchored.value, size: anchored.size, state: state.with(alias_nodes: total)))
    none -> Source.fail(src, pos, "undefined alias *#{name}")
  end
end

def scalar(src: Source.Source, meta: Types.Meta, plain: Bool, text: String, state: State) -> Result[Built]
  case Schema.scalar(text, plain, meta.tag)
    ok(value) -> ok(anchored(meta, Built(value: value, size: 1, state: state)))
    error(e) -> Source.fail(src, meta.pos, e.message)
  end
end

def seq(src: Source.Source, meta: Types.Meta, items: List[Types.Node], state: State) -> Result[Built]
  return tag_error(src, meta) if not Schema.collection_tag?(meta.tag, "seq")

  values: List[JSON.Value] = []
  size = 1
  current = state
  for item in items
    built = try compose(src, item, current)
    values = values.push(built.value)
    size += built.size
    current = built.state
  end

  ok(anchored(meta, Built(value: JSON.array(values), size: size, state: current)))
end

def map(src: Source.Source, meta: Types.Meta, entries: List[Types.Entry], state: State) -> Result[Built]
  return tag_error(src, meta) if not Schema.collection_tag?(meta.tag, "map")

  fields: Map[String, JSON.Value] = {}
  size = 1
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
    size += key.size + value.size
    current = value.state
  end

  ok(anchored(meta, Built(value: JSON.object(fields), size: size, state: current)))
end

def anchored(meta: Types.Meta, built: Built) -> Built
  return built if meta.anchor == ""

  anchors = built.state.anchors.put(meta.anchor, Anchored(value: built.value, size: built.size))
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

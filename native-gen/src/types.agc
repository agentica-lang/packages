## The canonical types of std/analysis as trees (pure): `List[Map[String, Cell]]` is a list of maps of String to Cell.

## A canonical type: a name (`Int`, `Point`, a resource), or a List, Map, Optional or Result of types.
export enum Type
  Named(String)
  ListOf(Type)
  MapOf(Type, Type)
  OptionalOf(Type)
  ResultOf(Type)
end

## The tree of the canonical type `text`.
export def parse(text: String) -> Type
  if text.start_with?("List[")
    return Type.ListOf(parse(inner(text, "List[")))
  end

  if text.start_with?("Optional[")
    return Type.OptionalOf(parse(inner(text, "Optional[")))
  end

  if text.start_with?("Result[")
    return Type.ResultOf(parse(inner(text, "Result[")))
  end

  if text.start_with?("Map[")
    parts = split_pair(inner(text, "Map["))
    return Type.MapOf(parse(parts[0]), parse(parts[1]))
  end

  return Type.Named(text)
end

## The canonical text of `type`, as std/analysis writes it.
export def text(type: Type) -> String
  case type
    Type.Named(name) -> return name
    Type.ListOf(item) -> return "List[#{text(item)}]"
    Type.MapOf(key, value) -> return "Map[#{text(key)}, #{text(value)}]"
    Type.OptionalOf(item) -> return "Optional[#{text(item)}]"
    Type.ResultOf(item) -> return "Result[#{text(item)}]"
  end
end

## `type` as a part of a C name: `list_Float`, `map_String_list_Int`, `optional_Point`.
export def mangled(type: Type) -> String
  case type
    Type.Named(name) -> return name
    Type.ListOf(item) -> return "list_#{mangled(item)}"
    Type.MapOf(key, value) -> return "map_#{mangled(key)}_#{mangled(value)}"
    Type.OptionalOf(item) -> return "optional_#{mangled(item)}"
    Type.ResultOf(item) -> return "result_#{mangled(item)}"
  end
end

## The types inside `type`, `type` included, each after the ones it holds.
export def inside_out(type: Type) -> List[Type]
  case type
    Type.Named(_) -> return [type]
    Type.ListOf(item) -> return inside_out(item).push(type)
    Type.MapOf(key, value) -> return inside_out(key).concat(inside_out(value)).push(type)
    Type.OptionalOf(item) -> return inside_out(item).push(type)
    Type.ResultOf(item) -> return inside_out(item).push(type)
  end
end

# The text between `start` and the last `]` of `text`.
def inner(text: String, start: String) -> String
  return text.slice(start.length, text.length - start.length - 1)
end

# The key and value of `Map[K, V]`: split at the `, ` outside brackets.
def split_pair(text: String) -> List[String]
  depth = 0
  at = 0
  for c in text.split("")
    if c == "["
      depth += 1
    elsif c == "]"
      depth -= 1
    elsif c == "," and depth == 0
      return [text.slice(0, at), text.slice(at + 2, text.length - at - 2)]
    end

    at += 1
  end

  return [text, ""]
end

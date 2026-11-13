## The canonical types of std/analysis as trees (pure): `List[Map[String, Cell]]` is a list of maps of String to Cell.

## A canonical type: a name (`Int`, `Point`, a resource), or a List, Map, Optional or Result of types.
enum Type
  Named(String)
  ListOf(Type)
  MapOf(Type, Type)
  OptionalOf(Type)
  ResultOf(Type)
end

## The tree of the canonical type `text`.
def parse(text: String) -> Type
  return Type.ListOf(parse(inner(text, "List["))) if text.start_with?("List[")

  return Type.OptionalOf(parse(inner(text, "Optional["))) if text.start_with?("Optional[")

  return Type.ResultOf(parse(inner(text, "Result["))) if text.start_with?("Result[")

  if text.start_with?("Map[")
    parts = split_pair(inner(text, "Map["))
    return Type.MapOf(parse(parts[0]), parse(parts[1]))
  end

  Type.Named(text)
end

## The canonical text of `type`, as std/analysis writes it.
def text(type: Type) -> String
  case type
    Type.Named(name) -> name
    Type.ListOf(item) -> "List[#{text(item)}]"
    Type.MapOf(key, value) -> "Map[#{text(key)}, #{text(value)}]"
    Type.OptionalOf(item) -> "Optional[#{text(item)}]"
    Type.ResultOf(item) -> "Result[#{text(item)}]"
  end
end

## `type` as a part of a C name: `list_Float`, `map_String_list_Int`, `optional_Point`.
def mangled(type: Type) -> String
  case type
    Type.Named(name) -> name
    Type.ListOf(item) -> "list_#{mangled(item)}"
    Type.MapOf(key, value) -> "map_#{mangled(key)}_#{mangled(value)}"
    Type.OptionalOf(item) -> "optional_#{mangled(item)}"
    Type.ResultOf(item) -> "result_#{mangled(item)}"
  end
end

## The types inside `type`, `type` included, each after the ones it holds.
def inside_out(type: Type) -> List[Type]
  case type
    Type.Named(_) -> [type]
    Type.ListOf(item) -> inside_out(item).push(type)
    Type.MapOf(key, value) -> inside_out(key).concat(inside_out(value)).push(type)
    Type.OptionalOf(item) -> inside_out(item).push(type)
    Type.ResultOf(item) -> inside_out(item).push(type)
  end
end

private

# The text between `start` and the last `]` of `text`.
def inner(text: String, start: String) -> String = text.slice(start.length, text.length - start.length - 1)

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

  [text, ""]
end

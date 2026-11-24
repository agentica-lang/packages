## The columns of a file: a flat schema has one leaf element per column, in order. A group or a repeated field is nested,
## which v1 does not read, so it is an error at open rather than a wrong table later.

import Metadata from "metadata"

REQUIRED = 0
OPTIONAL = 1
REPEATED = 2
INT96 = 3
UTF8 = 0

## One column: its name, its physical type, whether its values are text, the length of a fixed value, and whether it may
## be null.
struct Column
  name: String
  physical: Int
  text: Bool
  width: Int
  nullable: Bool
end

def columns(elements: List[Metadata.Element]) -> Result[List[Column]]
  return malformed("a schema with no root") if elements.empty?

  root = elements[0]
  return malformed("a root with #{root.children} children") if root.children < 0

  out: List[Column] = []
  for element in elements.drop(1)
    return unsupported("the nested column #{element.name}") if element.children >= 0
    return unsupported("the repeated column #{element.name}") if element.repetition == REPEATED
    return unsupported("the INT96 column #{element.name}") if element.physical == INT96
    return malformed("the column #{element.name} has no type") if element.physical < 0

    out = out.push(
      Column(
        name: element.name,
        physical: element.physical,
        text: element.converted == UTF8,
        width: element.type_length,
        nullable: element.repetition == OPTIONAL,
      ),
    )
  end

  return malformed("the root has #{root.children} children, the file has #{out.size}") if root.children != out.size

  ok(out)
end

## The largest definition level of a column: 1 when it may be null, 0 when it cannot.
def max_level(column: Column) -> Int
  return 1 if column.nullable

  0
end

private

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def unsupported[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.unsupported")

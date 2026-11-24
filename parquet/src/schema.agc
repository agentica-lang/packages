## The columns of a file: a flat schema has one leaf element per column, in order. A group or a repeated field is nested,
## which v1 does not read, so it is an error at open rather than a wrong table later.

import Errors from "errors"
import Metadata from "metadata"

## One column: its name, its physical type, whether its values are text, the length of a fixed value, and whether it may
## be null.
struct Column
  name: String
  physical: Int
  text: Bool
  width: Int
  nullable: Bool
  unsigned: Bool
end

def columns(elements: List[Metadata.Element]) -> Result[List[Column]]
  return Errors.malformed("a schema with no root") if elements.empty?

  root = elements[0]
  return Errors.malformed("a root with #{root.children} children") if root.children < 0

  out: List[Column] = []
  for element in elements.drop(1)
    return Errors.unsupported("the nested column #{element.name}") if element.children >= 0
    return Errors.unsupported("the repeated column #{element.name}") if element.repetition == REPEATED
    return Errors.unsupported("the INT96 column #{element.name}") if element.physical == INT96
    return Errors.malformed("the column #{element.name} has no type") if element.physical < 0
    return Errors.unsupported("the UINT_64 column #{element.name}") if element.converted == UINT_64

    out = out.push(
      Column(
        name: element.name,
        physical: element.physical,
        text: element.converted == UTF8,
        width: element.type_length,
        nullable: element.repetition == OPTIONAL,
        unsigned: element.converted == UINT_32,
      ),
    )
  end

  if root.children != out.size
    return Errors.malformed("the root has #{root.children} children, the file has #{out.size}")
  end

  ok(out)
end

## The largest definition level of a column: 1 when it may be null, 0 when it cannot.
def max_level(column: Column) -> Int
  return 1 if column.nullable

  0
end

private

OPTIONAL = 1
REPEATED = 2
INT96 = 3
UTF8 = 0
UINT_32 = 13
UINT_64 = 14

## The footer of a Parquet file: the schema elements, the row count, and the row groups with their column chunks.

import Fields from "fields"
import Thrift from "thrift"

## One schema element. `physical` is -1 for a group, `children` is -1 for a leaf, and `converted` is -1 when absent.
struct Element
  name: String
  physical: Int
  type_length: Int
  repetition: Int
  children: Int
  converted: Int
end

## One column chunk: its column path, its physical type and codec, its value count, and where its pages start.
struct Chunk
  path: List[String]
  physical: Int
  codec: Int
  count: Int
  start: Int
  size: Int
end

struct Group
  rows: Int
  chunks: List[Chunk]
end

struct Meta
  elements: List[Element]
  rows: Int
  groups: List[Group]
end

## The footer of a file, the FileMetaData struct, as its schema, row count and row groups.
def read_meta(footer: Bytes) -> Result[Meta]
  root = try Thrift.read_struct(footer, 0)
  fields = root.value
  elements = try elements_of(fields)
  rows = try Fields.required_number(fields, 3)
  groups = try groups_of(fields)
  ok(Meta(elements: elements, rows: rows, groups: groups))
end

private

def elements_of(fields: Map[Int, Thrift.Value]) -> Result[List[Element]]
  items = try Fields.items_at(fields, 2)
  elements: List[Element] = []
  for item in items
    m = try Fields.as_struct(item)
    element = try read_element(m)
    elements = elements.push(element)
  end

  ok(elements)
end

def read_element(m: Map[Int, Thrift.Value]) -> Result[Element]
  name = try Fields.text(m, 4)
  physical = try Fields.number(m, 1, -1)
  type_length = try Fields.number(m, 2, 0)
  repetition = try Fields.number(m, 3, 0)
  children = try Fields.number(m, 5, -1)
  converted = try Fields.number(m, 6, -1)
  ok(
    Element(
      name: name,
      physical: physical,
      type_length: type_length,
      repetition: repetition,
      children: children,
      converted: converted,
    ),
  )
end

def groups_of(fields: Map[Int, Thrift.Value]) -> Result[List[Group]]
  items = try Fields.items_at(fields, 4)
  groups: List[Group] = []
  for item in items
    m = try Fields.as_struct(item)
    group = try read_group(m)
    groups = groups.push(group)
  end

  ok(groups)
end

def read_group(m: Map[Int, Thrift.Value]) -> Result[Group]
  rows = try Fields.number(m, 3, 0)
  columns = try Fields.items_at(m, 1)
  chunks: List[Chunk] = []
  for item in columns
    column = try Fields.as_struct(item)
    meta = try Fields.struct_at(column, 3)
    chunk = try read_chunk(meta)
    chunks = chunks.push(chunk)
  end

  ok(Group(rows: rows, chunks: chunks))
end

def read_chunk(meta: Map[Int, Thrift.Value]) -> Result[Chunk]
  physical = try Fields.required_number(meta, 1)
  path = try strings_of(meta)
  codec = try Fields.number(meta, 4, 0)
  count = try Fields.required_number(meta, 5)
  size = try Fields.required_number(meta, 7)
  data_page = try Fields.required_number(meta, 9)
  dictionary = try Fields.number(meta, 11, -1)
  start = data_page
  if dictionary > 0 and dictionary < data_page
    start = dictionary
  end

  ok(Chunk(path: path, physical: physical, codec: codec, count: count, start: start, size: size))
end

def strings_of(meta: Map[Int, Thrift.Value]) -> Result[List[String]]
  items = try Fields.items_at(meta, 3)
  names: List[String] = []
  for item in items
    name = try Fields.as_text(item)
    names = names.push(name)
  end

  ok(names)
end

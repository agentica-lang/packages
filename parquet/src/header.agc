## A page header: its kind, its sizes, and what its data page header says. `compressed` bytes of body follow it at `start`.

import Errors from "errors"
import Fields from "fields"
import Thrift from "thrift"

## The v2 level byte counts are zero for other pages, and `level_encoding` is the encoding of the definition levels.
struct Header
  kind: Int
  size: Int
  compressed: Int
  count: Int
  encoding: Int
  level_encoding: Int
  definition_bytes: Int
  repetition_bytes: Int
  is_compressed: Bool
  start: Int
end

def read_header(data: Bytes, pos: Int) -> Result[Header]
  root = try Thrift.read_struct(data, pos)
  m = root.value
  kind = try Fields.required_number(m, 1)
  size = try Fields.required_number(m, 2)
  compressed = try Fields.required_number(m, 3)
  if size < 0 or compressed < 0 or size > MAX_PAGE_BYTES
    return Errors.malformed("a page of #{size} bytes packed in #{compressed}")
  end

  if kind == DATA_PAGE
    inner = try Fields.struct_at(m, 5)
    simple_header(kind, size, compressed, inner, root.next)
  elsif kind == DICTIONARY_PAGE
    inner = try Fields.struct_at(m, 7)
    simple_header(kind, size, compressed, inner, root.next)
  elsif kind == DATA_PAGE_V2
    inner = try Fields.struct_at(m, 8)
    v2_header(size, compressed, inner, root.next)
  else
    Errors.unsupported("the page type #{kind}")
  end
end

def dictionary?(header: Header) -> Bool = header.kind == DICTIONARY_PAGE

def v2?(header: Header) -> Bool = header.kind == DATA_PAGE_V2

## Whether the definition levels of a v1 page are RLE, the only encoding that is read.
def rle_levels?(header: Header) -> Bool = header.level_encoding == RLE

private

DATA_PAGE = 0
DICTIONARY_PAGE = 2
DATA_PAGE_V2 = 3
RLE = 3
MAX_PAGE_VALUES = 1048576
MAX_PAGE_BYTES = 268435456

def too_many[T](count: Int) -> Result[T] = Errors.malformed("a page of #{count} values")

def simple_header(kind: Int, size: Int, compressed: Int, inner: Map[Int, Thrift.Value], start: Int) -> Result[Header]
  count = try Fields.required_number(inner, 1)
  encoding = try Fields.required_number(inner, 2)
  level_encoding = RLE
  if kind == DATA_PAGE
    level_encoding = try Fields.number(inner, 3, RLE)
  end

  return too_many(count) if count < 0 or count > MAX_PAGE_VALUES

  ok(
    Header(
      kind: kind,
      size: size,
      compressed: compressed,
      count: count,
      encoding: encoding,
      level_encoding: level_encoding,
      definition_bytes: 0,
      repetition_bytes: 0,
      is_compressed: true,
      start: start,
    ),
  )
end

def v2_header(size: Int, compressed: Int, inner: Map[Int, Thrift.Value], start: Int) -> Result[Header]
  count = try Fields.required_number(inner, 1)
  encoding = try Fields.required_number(inner, 4)
  definition = try Fields.required_number(inner, 5)
  repetition = try Fields.required_number(inner, 6)
  is_compressed = try Fields.flag(inner, 7, true)
  if definition < 0 or repetition < 0
    return Errors.malformed("a page with #{definition} and #{repetition} level bytes")
  end

  return too_many(count) if count < 0 or count > MAX_PAGE_VALUES

  ok(
    Header(
      kind: DATA_PAGE_V2,
      size: size,
      compressed: compressed,
      count: count,
      encoding: encoding,
      level_encoding: RLE,
      definition_bytes: definition,
      repetition_bytes: repetition,
      is_compressed: is_compressed,
      start: start,
    ),
  )
end

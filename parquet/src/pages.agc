## The pages of a column chunk: the page header, the body after its codec, and the values of one data page.

import Binary from "std/binary"
import Fields from "fields"
import Plain from "plain"
import Rle from "rle"
import Snappy from "pkg/snappy/snappy"
import Thrift from "thrift"
import Values from "values"

DATA_PAGE = 0
DICTIONARY_PAGE = 2
DATA_PAGE_V2 = 3
UNCOMPRESSED = 0
SNAPPY = 1
GZIP = 2
PLAIN = 0
PLAIN_DICTIONARY = 2
RLE_DICTIONARY = 8
RLE = 3
MAX_PAGE_VALUES = 1048576
MAX_PAGE_BYTES = 268435456

## What a column's pages hold: its physical kind, the largest definition level, and its codec.
struct Layout
  kind: Plain.Kind
  max_level: Int
  codec: Int
end

## A page header. `compressed` bytes of body follow it at `start`. The v2 level byte counts are zero for other pages.
struct Header
  kind: Int
  size: Int
  compressed: Int
  count: Int
  encoding: Int
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
    return malformed("a page of #{size} bytes packed in #{compressed}")
  end

  if kind == DATA_PAGE
    inner = try Fields.struct_at(m, 5)
    simple_header(kind, size, compressed, inner, root.next)
  elsif kind == DICTIONARY_PAGE
    inner = try Fields.struct_at(m, 7)
    simple_header(kind, size, compressed, inner, root.next)
  elsif kind == DATA_PAGE_V2
    inner = try Fields.struct_at(m, 8)
    count = try Fields.required_number(inner, 1)
    encoding = try Fields.required_number(inner, 4)
    definition = try Fields.required_number(inner, 5)
    repetition = try Fields.required_number(inner, 6)
    is_compressed = try Fields.flag(inner, 7, true)
    return malformed("a page with #{definition} and #{repetition} level bytes") if definition < 0 or repetition < 0
    return too_many(count) if count < 0 or count > MAX_PAGE_VALUES

    ok(
      Header(
        kind: kind,
        size: size,
        compressed: compressed,
        count: count,
        encoding: encoding,
        definition_bytes: definition,
        repetition_bytes: repetition,
        is_compressed: is_compressed,
        start: root.next,
      ),
    )
  else
    unsupported("the page type #{kind}")
  end
end

## The body of a page after its codec, which must come to exactly `size` bytes.
def expand(codec: Int, raw: Bytes, size: Int) -> Result[Bytes]
  if codec == UNCOMPRESSED
    sized(raw, size)
  elsif codec == SNAPPY
    snappy(raw, size)
  elsif codec == GZIP
    case Zlib.gunzip(raw, size)
      ok(expanded) -> sized(expanded, size)
      error(_) -> malformed("a gzip page that does not expand to #{size} bytes")
    end
  else
    unsupported("the codec #{codec}")
  end
end

## The values of one data page (v1 or v2), with nulls where its definition levels say so.
def page_values(
  header: Header,
  raw: Bytes,
  layout: Layout,
  dictionary: Optional[Values.Values],
) -> Result[Values.Values]
  parts = try parts_of(header, raw, layout)
  levels = try definition_levels(parts.definitions, header.count, layout.max_level)
  defined = defined_count(levels, header.count, layout.max_level)
  values = try decode_values(header.encoding, parts.values, layout.kind, dictionary, defined)
  Values.spread(values, levels, layout.max_level)
end

## The values of a dictionary page, which the data pages that follow it index.
def dictionary_values(kind: Plain.Kind, header: Header, body: Bytes) -> Result[Values.Values]
  if header.encoding == PLAIN or header.encoding == PLAIN_DICTIONARY
    Plain.decode(kind, body, header.count)
  else
    unsupported("the dictionary encoding #{header.encoding}")
  end
end

private

MAX_LEVEL_LENGTH_BYTES = 4

## The definition level bytes and the value bytes of a page.
struct Parts
  definitions: Bytes
  values: Bytes
end

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def unsupported[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.unsupported")

def simple_header(kind: Int, size: Int, compressed: Int, inner: Map[Int, Thrift.Value], start: Int) -> Result[Header]
  count = try Fields.required_number(inner, 1)
  encoding = try Fields.required_number(inner, 2)
  return too_many(count) if count < 0 or count > MAX_PAGE_VALUES

  ok(
    Header(
      kind: kind,
      size: size,
      compressed: compressed,
      count: count,
      encoding: encoding,
      definition_bytes: 0,
      repetition_bytes: 0,
      is_compressed: true,
      start: start,
    ),
  )
end

def too_many[T](count: Int) -> Result[T] = malformed("a page of #{count} values")

# The block says its own length first; a length other than the page's is refused before anything is decoded.
def snappy(raw: Bytes, size: Int) -> Result[Bytes]
  preamble = try Thrift.varint(raw, 0)
  return malformed("a snappy page of #{preamble.value} bytes, not #{size}") if preamble.value != size

  case Snappy.decompress(raw)
    ok(expanded) -> sized(expanded, size)
    error(_) -> malformed("a snappy page that does not decode")
  end
end

def sized(bytes: Bytes, size: Int) -> Result[Bytes]
  return malformed("a page of #{bytes.size} bytes, not #{size}") if bytes.size != size

  ok(bytes)
end

def parts_of(header: Header, raw: Bytes, layout: Layout) -> Result[Parts]
  return v2_parts(header, raw, layout) if header.kind == DATA_PAGE_V2

  v1_parts(header, raw, layout)
end

# A v2 page keeps its level bytes uncompressed; only the value bytes are under the codec.
def v2_parts(header: Header, raw: Bytes, layout: Layout) -> Result[Parts]
  levels = header.definition_bytes + header.repetition_bytes
  return malformed("a page of #{levels} level bytes in #{raw.size}") if levels > raw.size
  return malformed("repetition levels in a flat column") if header.repetition_bytes != 0

  rest = raw.slice(levels, raw.size - levels)
  values = rest
  if header.is_compressed
    values = try expand(layout.codec, rest, header.size - levels)
  end

  ok(Parts(definitions: raw.slice(0, header.definition_bytes), values: values))
end

# A v1 page is under the codec as a whole; its definition levels come first, with a 4-byte length.
def v1_parts(header: Header, raw: Bytes, layout: Layout) -> Result[Parts]
  expanded = try expand(layout.codec, raw, header.size)
  return ok(Parts(definitions: "".bytes, values: expanded)) if layout.max_level == 0

  length = try level_length(expanded)
  ok(
    Parts(
      definitions: expanded.slice(MAX_LEVEL_LENGTH_BYTES, length),
      values: expanded.slice(MAX_LEVEL_LENGTH_BYTES + length, expanded.size - MAX_LEVEL_LENGTH_BYTES - length),
    ),
  )
end

def level_length(expanded: Bytes) -> Result[Int]
  return malformed("a page of #{expanded.size} bytes with no level length") if expanded.size < MAX_LEVEL_LENGTH_BYTES

  length = try Binary.read_u32_le(expanded, 0)
  if length > expanded.size - MAX_LEVEL_LENGTH_BYTES
    return malformed("#{length} level bytes in a page of #{expanded.size}")
  end

  ok(length)
end

def definition_levels(bytes: Bytes, count: Int, max_level: Int) -> Result[List[Int]]
  return ok([]) if max_level == 0

  Rle.decode(bytes, Rle.width_for(max_level), count)
end

def defined_count(levels: List[Int], count: Int, max_level: Int) -> Int
  return count if max_level == 0

  levels.select { |level| level == max_level }.size
end

def decode_values(
  encoding: Int,
  bytes: Bytes,
  kind: Plain.Kind,
  dictionary: Optional[Values.Values],
  defined: Int,
) -> Result[Values.Values]
  if encoding == PLAIN
    Plain.decode(kind, bytes, defined)
  elsif encoding == RLE and kind.physical == Plain.BOOLEAN
    rle_booleans(bytes, defined)
  elsif encoding == PLAIN_DICTIONARY or encoding == RLE_DICTIONARY
    indices = try dictionary_indices(bytes, defined)
    case dictionary
      some(values) -> Values.pick(values, indices)
      none -> no_dictionary(kind, indices)
    end
  else
    unsupported("the encoding #{encoding}")
  end
end

# Booleans in a v2 page: a 4-byte length, then bit-width-1 hybrid runs.
def rle_booleans(bytes: Bytes, defined: Int) -> Result[Values.Values]
  length = try level_length(bytes)
  bits = try Rle.decode(bytes.slice(MAX_LEVEL_LENGTH_BYTES, length), 1, defined)
  ok(Values.Values.Booleans(bits.map { |bit| some(bit == 1) }))
end

# A page with no defined value needs no dictionary.
def no_dictionary(kind: Plain.Kind, indices: List[Int]) -> Result[Values.Values]
  return ok(Plain.empty(kind)) if indices.empty?

  malformed("a dictionary page is missing")
end

# The index width is the first byte; the indices are the hybrid runs after it.
def dictionary_indices(bytes: Bytes, defined: Int) -> Result[List[Int]]
  return malformed("a dictionary page with no index width") if bytes.size == 0

  Rle.decode(bytes.drop(1), bytes[0], defined)
end

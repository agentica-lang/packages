## The values of the data pages and the dictionary pages of a column chunk.

import Binary from "std/binary"
import Compression from "codec"
import Errors from "errors"
import Header from "header"
import Plain from "plain"
import Rle from "rle"
import Values from "values"

## What a column's pages hold: its physical kind, the largest definition level, and its codec.
struct Layout
  kind: Plain.Kind
  max_level: Int
  codec: Int
end

## The values of one data page (v1 or v2), with nulls where its definition levels say so.
def page_values(
  header: Header.Header,
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
def dictionary_values(kind: Plain.Kind, header: Header.Header, body: Bytes) -> Result[Values.Values]
  if header.encoding == PLAIN or header.encoding == PLAIN_DICTIONARY
    Plain.decode(kind, body, header.count)
  else
    Errors.unsupported("the dictionary encoding #{header.encoding}")
  end
end

private

LEVEL_LENGTH_BYTES = 4
PLAIN = 0
PLAIN_DICTIONARY = 2
RLE_DICTIONARY = 8
RLE = 3

## The definition level bytes and the value bytes of a page.
struct Parts
  definitions: Bytes
  values: Bytes
end

def parts_of(header: Header.Header, raw: Bytes, layout: Layout) -> Result[Parts]
  return v2_parts(header, raw, layout) if Header.v2?(header)

  v1_parts(header, raw, layout)
end

# A v2 page keeps its level bytes uncompressed; only the value bytes are under the codec.
def v2_parts(header: Header.Header, raw: Bytes, layout: Layout) -> Result[Parts]
  levels = header.definition_bytes + header.repetition_bytes
  return Errors.malformed("a page of #{levels} level bytes in #{raw.size}") if levels > raw.size
  return Errors.malformed("repetition levels in a flat column") if header.repetition_bytes != 0

  rest = raw.slice(levels, raw.size - levels)
  values = rest
  if header.is_compressed
    values = try Compression.expand(layout.codec, rest, header.size - levels)
  elsif rest.size != header.size - levels
    return Errors.malformed("a page of #{rest.size} value bytes, not #{header.size - levels}")
  end

  ok(Parts(definitions: raw.slice(0, header.definition_bytes), values: values))
end

# A v1 page is under the codec as a whole; its definition levels come first, with a 4-byte length.
def v1_parts(header: Header.Header, raw: Bytes, layout: Layout) -> Result[Parts]
  expanded = try Compression.expand(layout.codec, raw, header.size)
  return ok(Parts(definitions: "".bytes, values: expanded)) if layout.max_level == 0
  return Errors.unsupported("definition levels of encoding #{header.level_encoding}") if !Header.rle_levels?(header)

  length = try level_length(expanded)
  ok(
    Parts(
      definitions: expanded.slice(LEVEL_LENGTH_BYTES, length),
      values: expanded.slice(LEVEL_LENGTH_BYTES + length, expanded.size - LEVEL_LENGTH_BYTES - length),
    ),
  )
end

def level_length(expanded: Bytes) -> Result[Int]
  if expanded.size < LEVEL_LENGTH_BYTES
    return Errors.malformed("a page of #{expanded.size} bytes with no level length")
  end

  length = (try Binary.read_u32_le(expanded, 0)).to_i
  if length > expanded.size - LEVEL_LENGTH_BYTES
    return Errors.malformed("#{length} level bytes in a page of #{expanded.size}")
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
    Errors.unsupported("the encoding #{encoding}")
  end
end

# Booleans under the RLE encoding: a 4-byte length, then bit-width-1 hybrid runs.
def rle_booleans(bytes: Bytes, defined: Int) -> Result[Values.Values]
  length = try level_length(bytes)
  bits = try Rle.decode(bytes.slice(LEVEL_LENGTH_BYTES, length), 1, defined)
  wide = bits.select { |bit| bit > 1 }
  return Errors.malformed("a boolean run of the value #{wide[0]}") if !wide.empty?

  ok(Values.Values.Booleans(bits.map { |bit| some(bit == 1) }))
end

# A page with no defined value needs no dictionary.
def no_dictionary(kind: Plain.Kind, indices: List[Int]) -> Result[Values.Values]
  return ok(Plain.empty(kind)) if indices.empty?

  Errors.malformed("a dictionary page is missing")
end

# The index width is the first byte; the indices are the hybrid runs after it.
def dictionary_indices(bytes: Bytes, defined: Int) -> Result[List[Int]]
  return Errors.malformed("a dictionary page with no index width") if bytes.size == 0

  Rle.decode(bytes.drop(1), bytes[0], defined)
end

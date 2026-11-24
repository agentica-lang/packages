## The PLAIN encoding of the defined values of a page, as values with no nulls. Every count is checked against the bytes
## before a loop runs, so a header that claims more values than the data holds is an error at once.

import Binary from "std/binary"
import Values from "values"

BOOLEAN = 0
INT32 = 1
INT64 = 2
INT96 = 3
FLOAT = 4
DOUBLE = 5
BYTE_ARRAY = 6
FIXED_LEN_BYTE_ARRAY = 7

## A physical type with what it needs: whether a byte array is text, and the length of a fixed-length value.
struct Kind
  physical: Int
  text: Bool
  width: Int
end

def decode(kind: Kind, data: Bytes, count: Int) -> Result[Values.Values]
  if kind.physical == BOOLEAN
    booleans(data, count)
  elsif kind.physical == INT32
    integers(data, count, 4, ->(at) { Binary.read_i32_le(data, at) })
  elsif kind.physical == INT64
    integers(data, count, 8, ->(at) { Binary.read_i64_le(data, at) })
  elsif kind.physical == FLOAT
    floats(data, count, 4, ->(at) { Binary.read_f32_le(data, at) })
  elsif kind.physical == DOUBLE
    floats(data, count, 8, ->(at) { Binary.read_f64_le(data, at) })
  elsif kind.physical == BYTE_ARRAY
    byte_arrays(kind, data, count)
  elsif kind.physical == FIXED_LEN_BYTE_ARRAY
    fixed_arrays(kind, data, count)
  else
    unsupported("the physical type #{kind.physical}")
  end
end

## The empty values of a kind, to join the pages of a column onto.
def empty(kind: Kind) -> Values.Values
  bools: List[Optional[Bool]] = []
  ints: List[Optional[Int]] = []
  floats: List[Optional[Float]] = []
  texts: List[Optional[String]] = []
  blobs: List[Optional[Bytes]] = []
  if kind.physical == BOOLEAN
    Values.Values.Booleans(bools)
  elsif kind.physical == INT32 or kind.physical == INT64
    Values.Values.Integers(ints)
  elsif kind.physical == FLOAT or kind.physical == DOUBLE
    Values.Values.Floats(floats)
  elsif kind.text
    Values.Values.Texts(texts)
  else
    Values.Values.Blobs(blobs)
  end
end

private

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def unsupported[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.unsupported")

def booleans(data: Bytes, count: Int) -> Result[Values.Values]
  return malformed("#{count} booleans in #{data.size} bytes") if count > data.size * 8

  bits: List[Optional[Bool]] = []
  for i in 0...count
    byte = data[i.shift_right(3)]
    bits = bits.push(some(byte.shift_right(i.bit_and(7)).bit_and(1) == 1))
  end

  ok(Values.Values.Booleans(bits))
end

def integers(data: Bytes, count: Int, width: Int, read: Fn[Int, Result[Int]]) -> Result[Values.Values]
  return malformed("#{count} integers in #{data.size} bytes") if count > data.size / width

  items: List[Optional[Int]] = []
  for i in 0...count
    value = try read.call(i * width)
    items = items.push(some(value))
  end

  ok(Values.Values.Integers(items))
end

def floats(data: Bytes, count: Int, width: Int, read: Fn[Int, Result[Float]]) -> Result[Values.Values]
  return malformed("#{count} floats in #{data.size} bytes") if count > data.size / width

  items: List[Optional[Float]] = []
  for i in 0...count
    value = try read.call(i * width)
    items = items.push(some(value))
  end

  ok(Values.Values.Floats(items))
end

# A byte array: a 4-byte length, then the bytes. Text is checked as UTF-8.
def byte_arrays(kind: Kind, data: Bytes, count: Int) -> Result[Values.Values]
  at = 0
  texts: List[Optional[String]] = []
  blobs: List[Optional[Bytes]] = []
  for _ in 0...count
    length = try Binary.read_u32_le(data, at)
    return malformed("a value of #{length} bytes past the data") if length > data.size - at - 4

    value = data.slice(at + 4, length)
    at = at + 4 + length
    if kind.text
      texts = texts.push(some(try text(value)))
    else
      blobs = blobs.push(some(value))
    end
  end

  if kind.text
    ok(Values.Values.Texts(texts))
  else
    ok(Values.Values.Blobs(blobs))
  end
end

def fixed_arrays(kind: Kind, data: Bytes, count: Int) -> Result[Values.Values]
  return malformed("a fixed length of #{kind.width} bytes") if kind.width <= 0
  return malformed("#{count} values of #{kind.width} bytes in #{data.size} bytes") if count > data.size / kind.width

  texts: List[Optional[String]] = []
  blobs: List[Optional[Bytes]] = []
  for i in 0...count
    value = data.slice(i * kind.width, kind.width)
    if kind.text
      texts = texts.push(some(try text(value)))
    else
      blobs = blobs.push(some(value))
    end
  end

  if kind.text
    ok(Values.Values.Texts(texts))
  else
    ok(Values.Values.Blobs(blobs))
  end
end

def text(value: Bytes) -> Result[String]
  case String.from_bytes(value)
    ok(s) -> ok(s)
    error(_) -> malformed("a text value that is not UTF-8")
  end
end

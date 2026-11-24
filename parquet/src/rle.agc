## The RLE / bit-packed hybrid of Parquet, for the definition levels and the dictionary indices. A run header with its low
## bit clear repeats one value; with it set, the header counts groups of eight values that are bit-packed, least
## significant bit first.

import Errors from "errors"
import Thrift from "thrift"

MAX_WIDTH = 32

## The number of values, each `width` bits wide, at the start of `data`, which holds nothing else.
def decode(data: Bytes, width: Int, count: Int) -> Result[List[Int]]
  return Errors.malformed("a bit width of #{width}") if width < 0 or width > MAX_WIDTH
  return ok([]) if count == 0

  values: List[Int] = []
  at = 0
  while values.size < count
    header = try Thrift.varint(data, at)
    at = header.next
    if header.value.bit_and(1) == 0
      run = try repeated(data, at, width, header.value.shift_right(1), count - values.size)
      values = values + run.value
      at = run.next
    else
      groups = header.value.shift_right(1)
      packed = try bit_packed(data, at, width, groups, count - values.size)
      values = values + packed.value
      at = packed.next
    end
  end

  ok(values)
end

## The number of bits that hold every value from 0 to `max`.
def width_for(max: Int) -> Int
  width = 0
  power = 1
  while width < MAX_WIDTH and power <= max
    power = power * 2
    width = width + 1
  end

  width
end

private

# A run of `length` copies of one value, stored in as many bytes as its width needs (least significant byte first).
def repeated(data: Bytes, pos: Int, width: Int, length: Int, wanted: Int) -> Result[Thrift.Read[List[Int]]]
  bytes = (width + 7).shift_right(3)
  return Errors.malformed("a run value past the data") if bytes > data.size - pos

  value = 0
  for k in 0...bytes
    value = value + data[pos + k].shift_left(8 * k)
  end

  copies = length
  if copies > wanted
    copies = wanted
  end

  ok(Thrift.Read(value: (0...copies).map(->(_i) { value }), next: pos + bytes))
end

# `groups` groups of eight values, each group `width` bytes long, of which only `wanted` values are kept.
def bit_packed(data: Bytes, pos: Int, width: Int, groups: Int, wanted: Int) -> Result[Thrift.Read[List[Int]]]
  if width > 0 and groups > (data.size - pos) / width
    return Errors.malformed("#{groups} bit-packed groups past the data")
  end

  bytes = groups * width
  kept = wanted
  if groups < wanted
    kept = groups * 8
    if kept > wanted
      kept = wanted
    end
  end

  ok(Thrift.Read(value: unpack(data, pos, width, kept), next: pos + bytes))
end

def unpack(data: Bytes, start: Int, width: Int, count: Int) -> List[Int]
  one = 1
  mask = one.shift_left(width) - 1
  values: List[Int] = []
  buffer = 0
  bits = 0
  at = start
  for _ in 0...count
    while bits < width
      buffer = buffer + data[at].shift_left(bits)
      at = at + 1
      bits = bits + 8
    end

    values = values.push(buffer.bit_and(mask))
    buffer = buffer.shift_right(width)
    bits = bits - width
  end

  values
end

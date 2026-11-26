## Huffman tables and the streams of literals they decode.

import Bits from "bits"
import Errors from "errors"
import Fse from "fse"

## A decoding table, indexed by the next `max_bits` bits of a stream. An entry holds the symbol and, at bit 8, the
## length of its code.
struct Table
  max_bits: Int
  entries: List[Int]
end

## A table and the byte after its description.
struct Tree
  table: Table
  next: Int
end

## Reads the description of a table from the bytes `start` up to `stop`.
def read_tree(data: Bytes, start: Int, stop: Int) -> Result[Tree]
  return Errors.malformed("missing Huffman tree") if start >= stop

  header = data[start]
  next = start + 1
  weights: List[Int] = []
  if header >= 128
    count = header - 127
    return Errors.malformed("truncated Huffman weights") if (count + 1) / 2 > stop - next

    for i in 0...count
      byte = data[next + i / 2]
      if i % 2 == 0
        weights = weights.push(byte.shift_right(4))
      else
        weights = weights.push(byte.bit_and(15))
      end
    end

    next = next + (count + 1) / 2
  else
    return Errors.malformed("truncated Huffman weights") if header == 0 or header > stop - next

    weights = try fse_weights(data.slice(next, header))
    next = next + header
  end

  table = try build(weights)
  ok(Tree(table: table, next: next))
end

## Decodes `count` literals from the bytes `start` up to `stop`: one stream, or four when `four` is set.
def decode(table: Table, data: Bytes, start: Int, stop: Int, count: Int, four: Bool) -> Result[Bytes]
  return from_values(try decode_stream(table, data, start, stop, count)) if not four
  return Errors.malformed("truncated Huffman jump table") if stop - start < 10

  first = Bits.read_le(data, start, 2)
  second = Bits.read_le(data, start + 2, 2)
  third = Bits.read_le(data, start + 4, 2)
  fourth = stop - start - 6 - first - second - third
  return Errors.malformed("the Huffman streams do not fit the literals") if fourth < 1

  segment = (count + 3) / 4
  last = count - 3 * segment
  return Errors.malformed("too few literals for four streams") if last < 0

  from = start + 6
  a = try decode_stream(table, data, from, from + first, segment)
  from = from + first
  b = try decode_stream(table, data, from, from + second, segment)
  from = from + second
  c = try decode_stream(table, data, from, from + third, segment)
  from = from + third
  d = try decode_stream(table, data, from, stop, last)
  from_values(a + b + c + d)
end

private

MAX_BITS = 11
MAX_WEIGHT_ACCURACY = 6
MAX_WEIGHTS = 255

# The values are symbols of a table, so they are bytes.
def from_values(values: List[Int]) -> Result[Bytes] = Bytes.from_list(values)

def fse_weights(data: Bytes) -> Result[List[Int]]
  head = try Fse.read_counts(data, 0, data.size, MAX_WEIGHTS, MAX_WEIGHT_ACCURACY)
  table = try Fse.build(head.counts, head.accuracy)
  entries = table.entries
  base = head.next
  size = data.size
  return Errors.malformed("truncated Huffman weights") if base >= size

  last = data[size - 1]
  return Errors.malformed("the Huffman weights have no end mark") if last == 0

  # `p` counts the bits left to read; the two states alternate and the stream ends once an update reads past it.
  p = (size - base - 1) * 8 + Bits.highbit(last)
  first = Bits.read_back(data, base, size, p, head.accuracy)
  p = p - head.accuracy
  second = Bits.read_back(data, base, size, p, head.accuracy)
  p = p - head.accuracy
  weights: List[Int] = []
  while weights.size <= MAX_WEIGHTS
    entry = entries[first]
    weights = weights.push(entry.bit_and(255))
    width = entry.shift_right(8).bit_and(255)
    first = entry.shift_right(16) + Bits.read_back(data, base, size, p, width)
    p = p - width
    if p < 0
      weights = weights.push(entries[second].bit_and(255))
      break
    end

    entry = entries[second]
    weights = weights.push(entry.bit_and(255))
    width = entry.shift_right(8).bit_and(255)
    second = entry.shift_right(16) + Bits.read_back(data, base, size, p, width)
    p = p - width
    if p < 0
      weights = weights.push(entries[first].bit_and(255))
      break
    end
  end

  return Errors.malformed("more than #{MAX_WEIGHTS} Huffman weights") if weights.size > MAX_WEIGHTS

  ok(weights)
end

# The weight of the last symbol is not stored: it makes the sum of the sizes a power of two.
def build(listed: List[Int]) -> Result[Table]
  total = 0
  for w in listed
    return Errors.malformed("Huffman weight #{w} over #{MAX_BITS}") if w > MAX_BITS

    if w > 0
      total = total + 1.shift_left(w - 1)
    end
  end

  return Errors.malformed("Huffman weights of no symbol") if total == 0

  top = Bits.highbit(total) + 1
  return Errors.malformed("Huffman code of #{top} bits") if top > MAX_BITS

  rest = 1.shift_left(top) - total
  return Errors.malformed("Huffman weights that do not complete a code") if rest.bit_and(rest - 1) != 0

  weights = listed.push(Bits.highbit(rest) + 1)
  entries: List[Int] = []
  for w in 1..top
    width = top + 1 - w
    run = 1.shift_left(w - 1)
    for symbol in 0...weights.size
      if weights[symbol] == w
        entries = entries + List.repeat(symbol + width.shift_left(8), run)
      end
    end
  end

  ok(Table(max_bits: top, entries: entries))
end

# The stream is read from its last byte: the bits under the highest set bit of that byte come first, most
# significant first. `acc` holds `avail` bits not used yet, with older bits above them that the masks cut off, and
# the zeros that follow the first byte count in `padded`: the stream is used up exactly when no real bit is left. The
# reference decoder accepts a stream with bits left over, or one read past its start, and gives data that depends on
# its implementation; this one refuses both.
def decode_stream(table: Table, data: Bytes, first: Int, stop: Int, count: Int) -> Result[List[Int]]
  return Errors.malformed("an empty Huffman stream") if stop <= first

  last = data[stop - 1]
  return Errors.malformed("a Huffman stream with no end mark") if last == 0

  avail = Bits.highbit(last)
  acc = last.bit_and(Bits.MASKS[avail])
  pos = stop - 2
  padded = 0
  entries = table.entries
  max_bits = table.max_bits
  mask = Bits.MASKS[max_bits]
  out: List[Int] = []
  for _ in 0...count
    if avail < max_bits
      while avail < 56
        if pos >= first
          acc = acc.shift_left(8).bit_or(data[pos])
          pos = pos - 1
        else
          acc = acc.shift_left(8)
          padded = padded + 8
        end

        avail = avail + 8
      end
    end

    entry = entries[acc.shift_right(avail - max_bits).bit_and(mask)]
    avail = avail - entry.shift_right(8)
    out = out.push(entry.bit_and(255))
  end

  if pos >= first or avail != padded
    return Errors.malformed("a Huffman stream that does not end where its literals do")
  end

  ok(out)
end

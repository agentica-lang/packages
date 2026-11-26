## The literals section of a compressed block.

import Bits from "bits"
import Errors from "errors"
import History from "history"
import Huffman from "huffman"

## The literals of a block, the byte after their section, and the Huffman table that a later block may reuse.
struct Section
  bytes: Bytes
  next: Int
  table: Optional[Huffman.Table]
end

## Reads the section at the start of `block`. `previous` is the table that a treeless section reuses.
def read(block: Bytes, previous: Optional[Huffman.Table], max_size: Int) -> Result[Section]
  return Errors.malformed("an empty compressed block") if block.empty?

  head = block[0]
  kind = head.bit_and(3)
  format = head.shift_right(2).bit_and(3)
  return plain(block, previous, kind == 1, format, max_size) if kind < 2

  compressed(block, previous, kind == 3, format, max_size)
end

private

HEADER_BYTES = [3, 3, 4, 5]
SIZE_BITS = [10, 10, 14, 18]

# A raw or an RLE section: formats 0 and 2 have a one byte header, 1 two bytes and 3 three bytes.
def plain(block: Bytes, previous: Optional[Huffman.Table], rle: Bool, format: Int, max_size: Int) -> Result[Section]
  header = 1
  shift = 3
  if format == 1
    header = 2
    shift = 4
  elsif format == 3
    header = 3
    shift = 4
  end

  return Errors.malformed("truncated literals header") if header > block.size

  size = Bits.read_le(block, 0, header).shift_right(shift)
  return Errors.malformed("#{size} literals over the block limit #{max_size}") if size > max_size

  if rle
    return Errors.malformed("truncated RLE literals") if header >= block.size

    return ok(Section(bytes: History.repeat(block.slice(header, 1), size), next: header + 1, table: previous))
  end

  return Errors.malformed("truncated literals") if size > block.size - header

  ok(Section(bytes: block.slice(header, size), next: header + size, table: previous))
end

def compressed(
  block: Bytes,
  previous: Optional[Huffman.Table],
  treeless: Bool,
  format: Int,
  max_size: Int,
) -> Result[Section]
  header = HEADER_BYTES[format]
  return Errors.malformed("truncated literals header") if header > block.size

  bits = SIZE_BITS[format]
  fields = Bits.read_le(block, 0, header).shift_right(4)
  count = fields.bit_and(Bits.MASKS[bits])
  size = fields.shift_right(bits).bit_and(Bits.MASKS[bits])
  return Errors.malformed("#{count} literals over the block limit #{max_size}") if count > max_size
  return Errors.malformed("truncated literals") if size > block.size - header

  stop = header + size
  start = header
  table = previous
  if not treeless
    tree = try Huffman.read_tree(block, header, stop)
    table = some(tree.table)
    start = tree.next
  end

  case table
    some(t) ->
      bytes = try Huffman.decode(t, block, start, stop, count, format != 0)
      ok(Section(bytes: bytes, next: stop, table: table))
    none -> Errors.malformed("a treeless literals section with no Huffman table before it")
  end
end

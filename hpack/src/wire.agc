import Huffman from "huffman"

struct Number
  value: Int
  next_offset: Int
end

struct Literal
  data: Bytes
  next_offset: Int
end

def read_int(block: Bytes, offset: Int, prefix: Int) -> Result[Number]
  return truncated(offset) if offset >= block.size
  mask = 1.shift_left(prefix) - 1
  value = block[offset].bit_and(mask)
  cursor = offset + 1
  return ok(Number(value: value, next_offset: cursor)) if value < mask
  shift = 0
  while cursor < block.size
    byte = block[cursor]
    digit = byte.bit_and(127)
    return overflow(offset) if digit > (MAX_INT - value).shift_right(shift)

    value = value + digit.shift_left(shift)
    cursor = cursor + 1
    return ok(Number(value: value, next_offset: cursor)) if byte < 128
    shift = shift + 7
    return overflow(offset) if shift > 56
  end

  truncated(cursor)
end

def read_string(block: Bytes, offset: Int, budget: Int) -> Result[Literal]
  length = try read_int(block, offset, 7)
  return truncated(length.next_offset) if length.value > block.size - length.next_offset
  compressed = block[offset] >= 128
  if not compressed and length.value > budget
    return error("header list exceeds its limit at byte #{offset}", kind: "hpack.header_list_size")
  end

  if compressed
    data = try Huffman.decode(block, length.next_offset, length.value, budget)
    return ok(Literal(data: data, next_offset: length.next_offset + length.value))
  end

  data = block.slice(length.next_offset, length.value)
  ok(Literal(data: data, next_offset: length.next_offset + length.value))
end

def write_int(value: Int, prefix: Int, flags: Int) -> Bytes
  mask = 1.shift_left(prefix) - 1
  return Bytes.from_list([flags + value]).unwrap! if value < mask
  octets = [flags + mask]
  remaining = value - mask
  while remaining >= 128
    octets = octets.push(remaining.bit_and(127) + 128)
    remaining = remaining.shift_right(7)
  end

  Bytes.from_list(octets.push(remaining)).unwrap!
end

private

MAX_INT = 9_223_372_036_854_775_807

def truncated[T](offset: Int) -> Result[T] = error("truncated hpack block at byte #{offset}", kind: "hpack.truncated")

def overflow(offset: Int) -> Result[Number] = error("hpack integer overflow at byte #{offset}", kind: "hpack.integer")

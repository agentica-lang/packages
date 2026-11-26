## The frames of a stream: their headers, their blocks and the checksum.

import Bits from "bits"
import Block from "block"
import Errors from "errors"
import History from "history"
import State from "state"
import Xxh64 from "xxh64"

## Decodes every frame of `data` and joins their content. A skippable frame adds nothing.
def decode(data: Bytes, max_size: Int) -> Result[Bytes]
  return Errors.malformed("no frame in an empty input") if data.empty?

  parts: List[Bytes] = []
  total = 0
  pos = 0
  while pos < data.size
    return Errors.malformed("truncated frame magic at byte #{pos}") if data.size - pos < 4

    magic = Bits.read_le(data, pos, 4)
    if magic == MAGIC
      frame = try read_frame(data, pos + 4, max_size - total)
      parts = parts.push(frame.content)
      total = total + frame.content.size
      pos = frame.next
    elsif magic.bit_and(SKIPPABLE_MASK) == SKIPPABLE
      return Errors.malformed("truncated skippable frame at byte #{pos}") if data.size - pos < 8

      skipped = Bits.read_le(data, pos + 4, 4)
      return Errors.malformed("skippable frame past the end at byte #{pos}") if skipped > data.size - pos - 8

      pos = pos + 8 + skipped
    else
      return Errors.malformed("no frame magic at byte #{pos}")
    end
  end

  ok(Bytes.concat(parts))
end

private

MAGIC = 0xFD2FB528
SKIPPABLE = 0x184D2A50
SKIPPABLE_MASK = 0xFFFFFFF0
MAX_BLOCK = 131072
MAX_WINDOW = 2147483648
DICTIONARY_BYTES = [0, 1, 2, 4]

struct Header
  window: Int
  content_size: Int
  checksum: Bool
  next: Int
end

struct Frame
  content: Bytes
  next: Int
end

# The content size is -1 when the header does not say it.
def read_header(data: Bytes, start: Int) -> Result[Header]
  return Errors.malformed("truncated frame header at byte #{start}") if start >= data.size

  descriptor = data[start]
  size_flag = descriptor.shift_right(6)
  single = descriptor.shift_right(5).bit_and(1) == 1
  return Errors.malformed("reserved bit of the frame header set at byte #{start}") if descriptor.bit_and(8) != 0

  window_bytes = 1
  if single
    window_bytes = 0
  end

  dictionary_bytes = DICTIONARY_BYTES[descriptor.bit_and(3)]
  size_bytes = 1.shift_left(size_flag)
  if size_flag == 0 and not single
    size_bytes = 0
  end

  if window_bytes + dictionary_bytes + size_bytes > data.size - start - 1
    return Errors.malformed("truncated frame header at byte #{start}")
  end

  pos = start + 1
  window = 0
  if not single
    exponent = data[pos].shift_right(3)
    mantissa = data[pos].bit_and(7)
    window = 1.shift_left(10 + exponent) + 1.shift_left(7 + exponent) * mantissa
    pos = pos + 1
  end

  if Bits.read_le(data, pos, dictionary_bytes) != 0
    return Errors.unsupported("a frame that needs a dictionary (id #{Bits.read_le(data, pos, dictionary_bytes)})")
  end

  pos = pos + dictionary_bytes
  content_size = -1
  if size_bytes > 0
    content_size = Bits.read_le(data, pos, size_bytes)
    if size_flag == 1
      content_size = content_size + 256
    end

    return Errors.too_large("a frame of more than 9223372036854775807 bytes") if content_size < 0
  end

  if single
    window = content_size
  end

  ok(Header(window: window, content_size: content_size, checksum: descriptor.bit_and(4) != 0, next: pos + size_bytes))
end

def read_frame(data: Bytes, start: Int, room: Int) -> Result[Frame]
  header = try read_header(data, start)
  if header.content_size > room
    return Errors.too_large("the frame says it holds #{header.content_size} bytes, over the limit")
  end

  return Errors.unsupported("a window of #{header.window} bytes, over #{MAX_WINDOW}") if header.window > MAX_WINDOW

  limits = State.Limits(window: header.window, block_max: min_of(header.window, MAX_BLOCK))
  state = State.fresh()
  pos = header.next
  last = false
  while not last
    return Errors.malformed("truncated block header at byte #{pos}") if data.size - pos < 3

    word = Bits.read_le(data, pos, 3)
    last = word.bit_and(1) == 1
    kind = word.shift_right(1).bit_and(3)
    size = word.shift_right(3)
    pos = pos + 3
    return Errors.malformed("a block of the reserved type at byte #{pos - 3}") if kind == 3

    return Errors.malformed("a block of #{size} bytes over #{limits.block_max}") if size > limits.block_max

    if kind == 0
      return Errors.malformed("truncated raw block at byte #{pos}") if size > data.size - pos
      return Errors.too_large("the content is over the limit") if state.history.produced + size > room

      state = state.with(history: History.append(state.history, data.slice(pos, size)))
      pos = pos + size
    elsif kind == 1
      return Errors.malformed("truncated RLE block at byte #{pos}") if pos >= data.size
      return Errors.too_large("the content is over the limit") if state.history.produced + size > room

      state = state.with(history: History.append(state.history, History.repeat(data.slice(pos, 1), size)))
      pos = pos + 1
    else
      return Errors.malformed("truncated block at byte #{pos}") if size > data.size - pos

      state = try Block.decode(state, data.slice(pos, size), limits)
      return Errors.too_large("the content is over the limit") if state.history.produced > room

      pos = pos + size
    end
  end

  content = History.output(state.history)
  if header.content_size >= 0 and content.size != header.content_size
    return Errors.malformed("the frame says #{header.content_size} bytes and holds #{content.size}")
  end

  if header.checksum
    return Errors.malformed("truncated checksum at byte #{pos}") if data.size - pos < 4
    if Bits.read_le(data, pos, 4) != Xxh64.hash(content).bit_and(0xFFFFFFFF)
      return Errors.malformed("the checksum of the content does not match")
    end

    pos = pos + 4
  end

  ok(Frame(content: content, next: pos))
end

def min_of(a: Int, b: Int) -> Int
  return a if a < b

  b
end

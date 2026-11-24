CHUNK = 4096
MAX_LENGTH = 4_294_967_295
PREAMBLE_BYTES = 5
OFFSET_WIDTHS = [0, 1, 2, 4]

struct Preamble
  length: Int
  next: Int
end

def decompress(data: Bytes) -> Result[Bytes]
  head = try read_preamble(data)
  expected = head.length
  pos = head.next
  size = data.size
  chunks: List[Bytes] = []
  tail = "".bytes
  produced = 0
  piece = tail
  while pos < size
    tag = data[pos]
    kind = tag.bit_and(3)
    at = pos
    pos = pos + 1
    if kind == 0
      length = tag.shift_right(2) + 1
      if length > 60
        width = length - 60
        return malformed("truncated literal length at byte #{at}") if width > size - pos
        length = read_le(data, pos, width) + 1
        pos = pos + width
      end

      return malformed("literal past the end of the input at byte #{at}") if length > size - pos
      return malformed("literal longer than the preamble at byte #{at}") if length > expected - produced
      piece = data.slice(pos, length)
      pos = pos + length
    else
      width = OFFSET_WIDTHS[kind]
      return malformed("truncated copy at byte #{at}") if width > size - pos
      offset = read_le(data, pos, width)
      length = 1 + tag.shift_right(2)
      if kind == 1
        length = 4 + tag.shift_right(2).bit_and(7)
        offset = offset + tag.shift_right(5).shift_left(8)
      end

      pos = pos + width
      return malformed("copy offset 0 at byte #{at}") if offset == 0
      return malformed("copy offset #{offset} before the start at byte #{at}") if offset > produced
      return malformed("copy longer than the preamble at byte #{at}") if length > expected - produced
      piece = copy_piece(chunks, tail, produced, offset, length)
    end

    produced = produced + piece.size
    tail = tail + piece
    if tail.size >= CHUNK
      full = tail.size / CHUNK
      for j in 0...full
        chunks = chunks.push(tail.slice(j * CHUNK, CHUNK))
      end

      tail = tail.drop(full * CHUNK)
    end
  end

  return malformed("decoded #{produced} bytes, the preamble says #{expected}") if produced != expected

  ok(Bytes.concat(chunks.push(tail)))
end

private

def malformed[T](message: String) -> Result[T] = error("snappy: #{message}", kind: "snappy.malformed")

def read_preamble(data: Bytes) -> Result[Preamble]
  length = 0
  i = 0
  while i < data.size and i < PREAMBLE_BYTES
    byte = data[i]
    length = length + byte.bit_and(0x7F).shift_left(7 * i)
    i = i + 1
    if byte < 0x80
      return malformed("length #{length} over 4294967295") if length > MAX_LENGTH

      return ok(Preamble(length: length, next: i))
    end
  end

  malformed("truncated or too long length preamble")
end

def read_le(data: Bytes, pos: Int, width: Int) -> Int
  value = 0
  for k in 0...width
    value = value + data[pos + k].shift_left(8 * k)
  end

  value
end

# A copy is at most 64 bytes, so it spans two chunks at most. An offset shorter than the length repeats the last
# `offset` bytes.
def copy_piece(chunks: List[Bytes], tail: Bytes, produced: Int, offset: Int, length: Int) -> Bytes
  start = produced - offset
  return window(chunks, tail, start, length) if offset >= length

  pattern = window(chunks, tail, start, offset)
  Bytes.concat(List.repeat(pattern, length / offset + 1)).take(length)
end

def window(chunks: List[Bytes], tail: Bytes, start: Int, length: Int) -> Bytes
  index = start / CHUNK
  skip = start - index * CHUNK
  full = chunks.size
  return tail.slice(start - full * CHUNK, length) if index >= full
  return chunks[index].slice(skip, length) if skip + length <= CHUNK

  head = chunks[index].slice(skip, CHUNK - skip)
  following = (chunks + [tail])[index + 1]
  head + following.slice(0, length - head.size)
end

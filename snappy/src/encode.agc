MIN_MATCH = 4
MAX_COPY = 64
COPY_1_MAX_LENGTH = 11
COPY_1_MAX_OFFSET = 2047
COPY_2_MAX_OFFSET = 65_535
LENGTH_WIDTHS = [0x100, 0x10000, 0x1000000]
# As in the reference encoder, the step grows by one every 32 misses, so incompressible data costs few lookups.
MISS_SHIFT = 5

def compress(data: Bytes) -> Bytes
  size = data.size
  parts = [varint(size)]
  seen: Map[Int, Int] = {}
  literal_start = 0
  i = 0
  misses = 0
  while i + MIN_MATCH <= size
    key = word(data, i)
    candidate = seen.get(key, -1)
    seen = seen.put(key, i)
    if candidate < 0
      i = i + 1 + misses.shift_right(MISS_SHIFT)
      misses = misses + 1
      next
    end

    misses = 0
    length = MIN_MATCH + match_length(data, candidate + MIN_MATCH, i + MIN_MATCH)
    if i > literal_start
      parts = parts.push(literal(data, literal_start, i - literal_start))
    end

    parts = parts.push(copies(i - candidate, length))
    i = i + length
    literal_start = i
  end

  if size > literal_start
    parts = parts.push(literal(data, literal_start, size - literal_start))
  end

  Bytes.concat(parts)
end

private

def word(data: Bytes, i: Int) -> Int
  data[i] + data[i + 1].shift_left(8) + data[i + 2].shift_left(16) + data[i + 3].shift_left(24)
end

def match_length(data: Bytes, from: Int, to: Int) -> Int
  length = 0
  while to + length < data.size and data[from + length] == data[to + length]
    length = length + 1
  end

  length
end

# The values are bytes by construction, so from_list cannot fail.
def bytes_of(values: List[Int]) -> Bytes = Bytes.from_list(values).unwrap!

def varint(value: Int) -> Bytes
  values: List[Int] = []
  rest = value
  while rest >= 0x80
    values = values.push(rest.bit_and(0x7F).bit_or(0x80))
    rest = rest.shift_right(7)
  end

  bytes_of(values.push(rest))
end

def little_endian(value: Int, width: Int) -> List[Int]
  (0...width).map(->(k) { value.shift_right(8 * k).bit_and(0xFF) })
end

def literal(data: Bytes, start: Int, length: Int) -> Bytes
  rest = length - 1
  return bytes_of([rest.shift_left(2)]) + data.slice(start, length) if rest < 60

  width = LENGTH_WIDTHS.take_while(->(limit) { rest >= limit }).size + 1
  bytes_of([(59 + width).shift_left(2)] + little_endian(rest, width)) + data.slice(start, length)
end

def copies(offset: Int, length: Int) -> Bytes
  parts: List[Bytes] = []
  rest = length
  while rest >= MAX_COPY + MIN_MATCH
    parts = parts.push(copy(offset, MAX_COPY))
    rest = rest - MAX_COPY
  end

  if rest > MAX_COPY
    parts = parts.push(copy(offset, MAX_COPY - MIN_MATCH))
    rest = rest - (MAX_COPY - MIN_MATCH)
  end

  Bytes.concat(parts.push(copy(offset, rest)))
end

def copy(offset: Int, length: Int) -> Bytes
  if length <= COPY_1_MAX_LENGTH and offset <= COPY_1_MAX_OFFSET
    tag = 1 + (length - MIN_MATCH).shift_left(2) + offset.shift_right(8).shift_left(5)
    bytes_of([tag, offset.bit_and(0xFF)])
  elsif offset <= COPY_2_MAX_OFFSET
    bytes_of([2 + (length - 1).shift_left(2)] + little_endian(offset, 2))
  else
    bytes_of([3 + (length - 1).shift_left(2)] + little_endian(offset, 4))
  end
end

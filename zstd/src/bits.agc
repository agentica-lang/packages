## Reads of bytes and bits that the decoders share.

## `MASKS[n]` is the `n` low bits set, for `n` up to 32.
MASKS = (0...33).map { |n| 1.shift_left(n) - 1 }

## `HIGH_BITS[n]` is the index of the highest bit of `n`, for `n` below 1024.
HIGH_BITS = (0...1024).map { |n| (0...11).select { |k| n.shift_right(k) > 0 }.size - 1 }

## The `width` bytes at `pos` as a little-endian integer; the caller checked that they are in `data`.
def read_le(data: Bytes, pos: Int, width: Int) -> Int
  value = 0
  for k in 0...width
    value = value.bit_or(data[pos + k].shift_left(8 * k))
  end

  value
end

## The index of the highest bit of `n`, which is at least 1.
def highbit(n: Int) -> Int
  bit = 0
  while n.shift_right(bit + 1) > 0
    bit = bit + 1
  end

  bit
end

## `n` bits (at most 16) that start at bit `bit` of the bytes from `base` up to `stop`, least significant bit first.
## Bits past `stop` read as zeros.
def peek_bits(data: Bytes, base: Int, stop: Int, bit: Int, n: Int) -> Int
  index = base + bit / 8
  word = 0
  for k in 0...3
    if index + k < stop
      word = word + data[index + k].shift_left(8 * k)
    end
  end

  word.shift_right(bit % 8).bit_and(MASKS[n])
end

## `n` bits (at most 16) that end at bit `p` of a stream read backwards: the bits `p - n` up to `p` of the bytes from
## `base` up to `stop`. What lies before the first bit reads as zeros.
def read_back(data: Bytes, base: Int, stop: Int, p: Int, n: Int) -> Int
  return 0 if n == 0 or p <= 0
  return peek_bits(data, base, stop, p - n, n) if p >= n

  peek_bits(data, base, stop, 0, p).shift_left(n - p)
end

## XXH64 with seed 0, for the content checksum of a frame.

PRIME1 = -7046029288634856825
PRIME2 = -4417276706812531889
PRIME3 = 1609587929392839161
PRIME4 = -8796714831421723037
PRIME5 = 2870177450012600261

## The 64 bits of the hash of `data`, as an `Int` (a hash above 2^63 reads negative).
def hash(data: Bytes) -> Int
  size = data.size
  pos = 0
  h = PRIME5
  if size >= 32
    v1 = add(PRIME1, PRIME2)
    v2 = PRIME2
    v3 = 0
    v4 = 0 - PRIME1
    while pos + 32 <= size
      v1 = round(v1, word(data, pos))
      v2 = round(v2, word(data, pos + 8))
      v3 = round(v3, word(data, pos + 16))
      v4 = round(v4, word(data, pos + 24))
      pos = pos + 32
    end

    h = add(add(rotl(v1, 1), rotl(v2, 7)), add(rotl(v3, 12), rotl(v4, 18)))
    h = merge(h, v1)
    h = merge(h, v2)
    h = merge(h, v3)
    h = merge(h, v4)
  end

  h = add(h, size)
  while pos + 8 <= size
    h = add(mul(rotl(h.bit_xor(round(0, word(data, pos))), 27), PRIME1), PRIME4)
    pos = pos + 8
  end

  if pos + 4 <= size
    h = add(mul(rotl(h.bit_xor(mul(half(data, pos), PRIME1)), 23), PRIME2), PRIME3)
    pos = pos + 4
  end

  while pos < size
    h = mul(rotl(h.bit_xor(mul(data[pos], PRIME5)), 11), PRIME1)
    pos = pos + 1
  end

  h = mul(h.bit_xor(h.shift_right_unsigned(33)), PRIME2)
  h = mul(h.bit_xor(h.shift_right_unsigned(29)), PRIME3)
  h.bit_xor(h.shift_right_unsigned(32))
end

private

# The sum and the product of two 64-bit values, wrapped: `Int` stops at overflow, so each works on pieces that fit.
def add(a: Int, b: Int) -> Int
  low = a.bit_and(0xFFFFFFFF) + b.bit_and(0xFFFFFFFF)
  high = a.shift_right_unsigned(32) + b.shift_right_unsigned(32) + low.shift_right(32)
  high.bit_and(0xFFFFFFFF).shift_left(32).bit_or(low.bit_and(0xFFFFFFFF))
end

def mul(a: Int, b: Int) -> Int
  a0 = a.bit_and(0xFFFF)
  a1 = a.shift_right(16).bit_and(0xFFFF)
  a2 = a.shift_right(32).bit_and(0xFFFF)
  a3 = a.shift_right_unsigned(48)
  b0 = b.bit_and(0xFFFF)
  b1 = b.shift_right(16).bit_and(0xFFFF)
  b2 = b.shift_right(32).bit_and(0xFFFF)
  b3 = b.shift_right_unsigned(48)
  low = a0 * b0 + (a0 * b1 + a1 * b0).shift_left(16)
  upper = a0 * b2 + a1 * b1 + a2 * b0 + (a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0).shift_left(16)
  high = low.shift_right(32) + upper
  high.bit_and(0xFFFFFFFF).shift_left(32).bit_or(low.bit_and(0xFFFFFFFF))
end

def rotl(x: Int, r: Int) -> Int = x.shift_left(r).bit_or(x.shift_right_unsigned(64 - r))

def round(acc: Int, input: Int) -> Int = mul(rotl(add(acc, mul(input, PRIME2)), 31), PRIME1)

def merge(acc: Int, lane: Int) -> Int = add(mul(acc.bit_xor(round(0, lane)), PRIME1), PRIME4)

def half(data: Bytes, pos: Int) -> Int
  (
    data[pos + 3]
      .shift_left(24)
      .bit_or(data[pos + 2].shift_left(16))
      .bit_or(data[pos + 1].shift_left(8))
      .bit_or(data[pos])
  )
end

def word(data: Bytes, pos: Int) -> Int = half(data, pos + 4).shift_left(32).bit_or(half(data, pos))

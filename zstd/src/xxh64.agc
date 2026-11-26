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
      v1 = lane(v1, data, pos)
      v2 = lane(v2, data, pos + 8)
      v3 = lane(v3, data, pos + 16)
      v4 = lane(v4, data, pos + 24)
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
    h = add(mul(rotl(h.bit_xor(lane(0, data, pos)), 27), FACTOR1), PRIME4)
    pos = pos + 8
  end

  if pos + 4 <= size
    h = add(mul(rotl(h.bit_xor(mul(half(data, pos), FACTOR1)), 23), FACTOR2), PRIME3)
    pos = pos + 4
  end

  while pos < size
    h = mul(rotl(h.bit_xor(mul(data[pos], FACTOR5)), 11), FACTOR1)
    pos = pos + 1
  end

  h = mul(h.bit_xor(h.shift_right_unsigned(33)), FACTOR2)
  h = mul(h.bit_xor(h.shift_right_unsigned(29)), FACTOR3)
  h.bit_xor(h.shift_right_unsigned(32))
end

private

LIMB = 0x3FFFFF
LOW32 = 0xFFFFFFFF
FACTOR1 = Factor(low: 2869895, middle: 2541079, high: 648055)
FACTOR2 = Factor(low: 1370959, middle: 3732639, high: 797482)
FACTOR3 = Factor(low: 3635705, middle: 2016888, high: 91494)
FACTOR5 = Factor(low: 1468357, middle: 2931801, high: 163150)

# A prime as three limbs of 22 bits, for `mul`.
struct Factor
  low: Int
  middle: Int
  high: Int
end

# The sum and the product of two 64-bit values, wrapped: `Int` stops at overflow, so each works on pieces that fit.
# `Int.wrapping_add` and `Int.wrapping_mul` (agentica #984, after Agentica 0.37.0) replace both, and the limbs.
def add(a: Int, b: Int) -> Int
  low = a.bit_and(LOW32) + b.bit_and(LOW32)
  high = a.shift_right_unsigned(32) + b.shift_right_unsigned(32) + low.shift_right(32)
  high.bit_and(LOW32).shift_left(32).bit_or(low.bit_and(LOW32))
end

# The low 64 bits of `a` times a prime. The limbs of 22 bits make products of 44 bits; the terms that weigh 2^66 and
# more are gone, and the others are added in two halves of 32 bits.
def mul(a: Int, b: Factor) -> Int
  a0 = a.bit_and(LIMB)
  a1 = a.shift_right(22).bit_and(LIMB)
  a2 = a.shift_right_unsigned(44)
  first = a0 * b.low
  second = a0 * b.middle + a1 * b.low
  third = a0 * b.high + a1 * b.middle + a2 * b.low
  low = first.bit_and(LOW32) + second.shift_left(22).bit_and(LOW32)
  high = first.shift_right(32) + second.shift_right(10) + third.shift_left(12) + low.shift_right(32)
  high.bit_and(LOW32).shift_left(32).bit_or(low.bit_and(LOW32))
end

def rotl(x: Int, r: Int) -> Int = x.shift_left(r).bit_or(x.shift_right_unsigned(64 - r))

def lane(acc: Int, data: Bytes, pos: Int) -> Int
  low = data[pos + 3].shift_left(24).bit_or(data[pos + 2].shift_left(16)).bit_or(data[pos + 1].shift_left(8))
  high = data[pos + 7].shift_left(24).bit_or(data[pos + 6].shift_left(16)).bit_or(data[pos + 5].shift_left(8))
  input = high.bit_or(data[pos + 4]).shift_left(32).bit_or(low.bit_or(data[pos]))
  mul(rotl(add(acc, mul(input, FACTOR2)), 31), FACTOR1)
end

def merge(acc: Int, v: Int) -> Int = add(mul(acc.bit_xor(mul(rotl(mul(v, FACTOR2), 31), FACTOR1)), FACTOR1), PRIME4)

def half(data: Bytes, pos: Int) -> Int
  (
    data[pos + 3]
      .shift_left(24)
      .bit_or(data[pos + 2].shift_left(16))
      .bit_or(data[pos + 1].shift_left(8))
      .bit_or(data[pos])
  )
end

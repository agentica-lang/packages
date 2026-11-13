## Seeds for the generators. A case is a pure function of its seed: the seed of a list item comes from the seed of the
## list and the index, never from the draws made before, so a seed replays a case whatever else ran. Seeds are 32 bits:
## a seed is masked to them, so 5 and 4294967301 are one seed.

# A 32-bit integer in 0 ..= 0xFFFFFFFF that depends on every bit of `value`.
def scramble(value: Int) -> Int
  x = value.bit_and(MASK)
  x = x.shift_right(16).bit_xor(x) * MULTIPLIER
  x = x.bit_and(MASK)
  x = x.shift_right(16).bit_xor(x) * MULTIPLIER
  x = x.bit_and(MASK)
  x.shift_right(16).bit_xor(x)
end

## The seed of part `index` of the value that `seed` makes.
def split(seed: Int, index: Int) -> Int = scramble(seed.bit_and(MASK) + (index + 1) * STRIDE)

## An Int in 0 ... bound, for a `bound` of 1 up to 2^62. Without bias: a draw in the incomplete last multiple of
## `bound` is made again from another seed.
def draw(seed: Int, bound: Int) -> Int
  # Masked first, so that the additions of the retries cannot overflow.
  masked = seed.bit_and(MASK)
  return narrow(masked, bound, NARROW - NARROW % bound) if bound <= NARROW

  wide(masked, bound, WIDE - WIDE % bound)
end

## A Float in 0.0 up to, not including, 1.0.
def unit(seed: Int) -> Float = scramble(seed).shift_right(2).to_f / 1073741824.0

private

MASK = 0xFFFFFFFF
# The multiplier of a 32-bit integer hash with good mixing. It is under 2^27, so a masked 32-bit value times it is
# under 2^59: no Int overflow.
MULTIPLIER = 0x45D9F3B
# Spreads the indexes of the parts of a seed (the golden ratio of 2^32); an index stays far under 2^30, so
# `(index + 1) * STRIDE` is under 2^62.
STRIDE = 0x9E3779B1
# Seeds for the second half of a wide draw and for a draw made again; they are not `STRIDE`, so they never repeat the
# seed of a part.
RETRY = 0x6A09E667
NARROW = 4294967296
WIDE = 4611686018427387904

def narrow(seed: Int, bound: Int, limit: Int) -> Int
  x = scramble(seed)
  return x % bound if x < limit

  narrow(seed + RETRY, bound, limit)
end

def wide(seed: Int, bound: Int, limit: Int) -> Int
  x = scramble(seed).shift_left(30).bit_or(scramble(seed + RETRY).bit_and(0x3FFFFFFF))
  return x % bound if x < limit

  wide(seed + 2 * RETRY, bound, limit)
end

## Seeds for the generators. A case is a pure function of its seed: the seed of a list item comes from the seed of the
## list and the index, never from the draws made before, so a seed replays a case whatever else ran.

MASK = 0xFFFFFFFF
# The multiplier of a 32-bit integer hash with good mixing. Both constants stay under 2^28, so a masked 32-bit value
# times either one is under 2^60: no Int overflow.
MULTIPLIER = 0x45D9F3B
OFFSET = 0x9E3779B1
WIDE_BOUND = 4294967296

# A 32-bit integer in 0 ..= 0xFFFFFFFF that depends on every bit of `value`.
export def scramble(value: Int) -> Int
  x = value.bit_and(MASK)
  x = x.shift_right(16).bit_xor(x) * MULTIPLIER
  x = x.bit_and(MASK)
  x = x.shift_right(16).bit_xor(x) * MULTIPLIER
  x = x.bit_and(MASK)
  return x.shift_right(16).bit_xor(x)
end

## The seed of part `index` of the value that `seed` makes.
export def split(seed: Int, index: Int) -> Int
  return scramble(scramble(seed).bit_xor(scramble(index + OFFSET)))
end

## An Int in 0 ... bound for a `bound` of 1 up to 2^62.
export def draw(seed: Int, bound: Int) -> Int
  high = scramble(seed)
  if bound <= WIDE_BOUND
    return high % bound
  end

  low = scramble(seed + OFFSET).bit_and(0x3FFFFFFF)
  return high.shift_left(30).bit_or(low) % bound
end

## A Float in 0.0 up to, not including, 1.0.
export def unit(seed: Int) -> Float
  return draw(seed, 1073741824).to_f / 1073741824.0
end

## Finite State Entropy tables: the counts that a table is described by, and the table that decodes with them.

import Bits from "bits"
import Errors from "errors"

## The predefined distributions, used with accuracy logs 6, 5 and 6.
LITERAL_LENGTH_DEFAULT = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1,
]
OFFSET_DEFAULT = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
MATCH_LENGTH_DEFAULT = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
]

## A decoding table. An entry holds the symbol, then the bits to read for the next state at bit 8 and the base of the
## next state at bit 16.
struct Table
  accuracy: Int
  entries: List[Int]
end

## The counts of a table (-1 is a probability below one), and the byte after its description.
struct Counts
  accuracy: Int
  counts: List[Int]
  next: Int
end

## Reads the description of a table from the bytes `start` up to `stop`.
def read_counts(data: Bytes, start: Int, stop: Int, max_symbol: Int, max_accuracy: Int) -> Result[Counts]
  accuracy = Bits.peek_bits(data, start, stop, 0, 4) + 5
  return Errors.malformed("FSE accuracy log #{accuracy} over #{max_accuracy}") if accuracy > max_accuracy

  remaining = 1.shift_left(accuracy) + 1
  threshold = 1.shift_left(accuracy)
  width = accuracy + 1
  bit = 4
  counts: List[Int] = []
  zero_before = false
  while remaining > 1 and counts.size <= max_symbol
    if zero_before
      run = 0
      flag = 3
      while flag == 3
        flag = Bits.peek_bits(data, start, stop, bit, 2)
        bit = bit + 2
        run = run + flag
      end

      return Errors.malformed("an FSE table has more than #{max_symbol + 1} symbols") if counts.size + run > max_symbol

      counts = counts + List.repeat(0, run)
    end

    low_max = 2 * threshold - 1 - remaining
    value = Bits.peek_bits(data, start, stop, bit, width - 1)
    if value < low_max
      bit = bit + width - 1
    else
      value = Bits.peek_bits(data, start, stop, bit, width)
      if value >= threshold
        value = value - low_max
      end

      bit = bit + width
    end

    count = value - 1
    remaining = remaining - count.abs
    return Errors.malformed("the counts of an FSE table add up to more than its size") if remaining < 1

    counts = counts.push(count)
    zero_before = count == 0
    while remaining < threshold
      width = width - 1
      threshold = threshold.shift_right(1)
    end
  end

  return Errors.malformed("the counts of an FSE table add up to less than its size") if remaining != 1

  size = (bit + 7) / 8
  return Errors.malformed("truncated FSE table") if size > stop - start

  ok(Counts(accuracy: accuracy, counts: counts, next: start + size))
end

## The decoding table of counts that add up to `1 << accuracy`.
def build(counts: List[Int], accuracy: Int) -> Result[Table]
  size = 1.shift_left(accuracy)
  symbols: List[Int] = List.repeat(0, size)
  following: List[Int] = []
  high = size - 1
  for s in 0...counts.size
    if counts[s] == -1
      symbols = symbols.set(high, s)
      high = high - 1
      following = following.push(1)
    else
      following = following.push(counts[s])
    end
  end

  step = size.shift_right(1) + size.shift_right(3) + 3
  mask = size - 1
  pos = 0
  for s in 0...counts.size
    for _ in 0...counts[s]
      symbols = symbols.set(pos, s)
      pos = (pos + step).bit_and(mask)
      while pos > high
        pos = (pos + step).bit_and(mask)
      end
    end
  end

  return Errors.malformed("the symbols of an FSE table do not fill it") if pos != 0

  entries: List[Int] = []
  for u in 0...size
    symbol = symbols[u]
    state = following[symbol]
    following = following.set(symbol, state + 1)
    bits = accuracy - Bits.highbit(state)
    base = state.shift_left(bits) - size
    entries = entries.push(symbol + bits.shift_left(8) + base.shift_left(16))
  end

  ok(Table(accuracy: accuracy, entries: entries))
end

## A table of one symbol: every state decodes it and reads no bits.
def single(symbol: Int) -> Table = Table(accuracy: 0, entries: [symbol])

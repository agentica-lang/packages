## The sequences section of a compressed block, and the sequences run over the literals.

import Bits from "bits"
import Errors from "errors"
import Fse from "fse"
import History from "history"
import State from "state"

## Reads the section at `start` of `block` and writes the sequences, then the literals that are left, to the history.
def run(state: State.State, literals: Bytes, block: Bytes, start: Int, limits: State.Limits) -> Result[State.State]
  size = block.size
  return Errors.malformed("a compressed block with no sequences section") if start >= size

  head = block[start]
  pos = start + 1
  count = head
  if head >= 255
    return Errors.malformed("truncated sequence count") if size - pos < 2

    count = block[pos] + block[pos + 1].shift_left(8) + COUNT_BASE
    pos = pos + 2
  elsif head >= 128
    return Errors.malformed("truncated sequence count") if size - pos < 1

    count = (head - 128).shift_left(8) + block[pos]
    pos = pos + 1
  end

  if count == 0
    return Errors.malformed("data after a block with no sequences") if pos != size

    return ok(state.with(history: History.append(state.history, literals)))
  end

  return Errors.malformed("truncated sequence modes") if pos >= size

  modes = block[pos]
  return Errors.malformed("reserved bits of the sequence modes") if modes.bit_and(3) != 0

  lengths = try load(modes.shift_right(6), LITERAL_LENGTHS, block, pos + 1, state.literal_lengths)
  offsets = try load(modes.shift_right(4).bit_and(3), OFFSETS, block, lengths.next, state.offsets)
  matches = try load(modes.shift_right(2).bit_and(3), MATCH_LENGTHS, block, offsets.next, state.match_lengths)
  plan = Plan(
    literal_lengths: lengths.table,
    offsets: offsets.table,
    match_lengths: matches.table,
    count: count,
    first: matches.next,
  )

  execute(state, plan, literals, block, limits)
end

private

COUNT_BASE = 0x7F00
LITERAL_LENGTH_BASES = (
  (0...16).to_a +
  [16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
)
LITERAL_LENGTH_BITS = List.repeat(0, 16) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
MATCH_LENGTH_BASES = (
  (3...35).to_a +
  [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539]
)
MATCH_LENGTH_BITS = List.repeat(0, 32) + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
LITERAL_LENGTHS = Kind(
  max_symbol: 35,
  max_accuracy: 9,
  default_counts: Fse.LITERAL_LENGTH_DEFAULT,
  default_accuracy: 6,
)
OFFSETS = Kind(max_symbol: 31, max_accuracy: 8, default_counts: Fse.OFFSET_DEFAULT, default_accuracy: 5)
MATCH_LENGTHS = Kind(max_symbol: 52, max_accuracy: 9, default_counts: Fse.MATCH_LENGTH_DEFAULT, default_accuracy: 6)

struct Kind
  max_symbol: Int
  max_accuracy: Int
  default_counts: List[Int]
  default_accuracy: Int
end

struct Loaded
  table: Fse.Table
  next: Int
end

struct Plan
  literal_lengths: Fse.Table
  offsets: Fse.Table
  match_lengths: Fse.Table
  count: Int
  first: Int
end

# Mode 0 is the predefined table, 1 one repeated symbol, 2 a table described in the block and 3 the table of the
# block before.
def load(mode: Int, kind: Kind, block: Bytes, pos: Int, previous: Optional[Fse.Table]) -> Result[Loaded]
  if mode == 0
    table = try Fse.build(kind.default_counts, kind.default_accuracy)
    return ok(Loaded(table: table, next: pos))
  end

  if mode == 1
    return Errors.malformed("truncated RLE sequence table") if pos >= block.size
    return Errors.malformed("symbol #{block[pos]} over #{kind.max_symbol}") if block[pos] > kind.max_symbol

    return ok(Loaded(table: Fse.single(block[pos]), next: pos + 1))
  end

  if mode == 2
    counts = try Fse.read_counts(block, pos, block.size, kind.max_symbol, kind.max_accuracy)
    table = try Fse.build(counts.counts, counts.accuracy)
    return ok(Loaded(table: table, next: counts.next))
  end

  case previous
    some(table) -> ok(Loaded(table: table, next: pos))
    none -> Errors.malformed("a repeated sequence table with no table before it")
  end
end

# The bits are read from the last byte of the block backwards, as in `Huffman.decode_stream`, with `acc` and `avail`
# for the bits not used yet; the refills are written out in the loop, since a function cannot change the `acc`, `avail`
# and `pos` of its caller. A sequence reads at most 47 bits for its offset and match length and 42 for the rest, so
# it refills (up to 56 bits) when fewer are left than it needs.
def execute(state: State.State, plan: Plan, literals: Bytes, block: Bytes, limits: State.Limits) -> Result[State.State]
  stop = block.size
  first = plan.first
  return Errors.malformed("no sequence bits") if first >= stop

  last = block[stop - 1]
  return Errors.malformed("the sequence bits have no end mark") if last == 0

  p = (stop - 1 - first) * 8 + Bits.highbit(last)
  ll_state = Bits.read_back(block, first, stop, p, plan.literal_lengths.accuracy)
  p = p - plan.literal_lengths.accuracy
  of_state = Bits.read_back(block, first, stop, p, plan.offsets.accuracy)
  p = p - plan.offsets.accuracy
  ml_state = Bits.read_back(block, first, stop, p, plan.match_lengths.accuracy)
  p = p - plan.match_lengths.accuracy
  acc = 0
  avail = 0
  pos = first - 1
  padded = 0
  if p > 0
    index = (p - 1) / 8
    avail = p - index * 8
    acc = block[first + index].bit_and(Bits.MASKS[avail])
    pos = first + index - 1
  else
    padded = 0 - p
  end

  ll_entries = plan.literal_lengths.entries
  of_entries = plan.offsets.entries
  ml_entries = plan.match_lengths.entries
  history = state.history
  base = history.produced
  produced = base
  block_max = limits.block_max
  window = limits.window
  total = plan.count
  masks = Bits.MASKS
  rep1 = state.rep1
  rep2 = state.rep2
  rep3 = state.rep3
  used = 0
  for i in 0...total
    if avail < 47
      while avail < 56
        if pos >= first
          acc = acc.shift_left(8).bit_or(block[pos])
          pos = pos - 1
          avail = avail + 8
        else
          acc = acc.shift_left(8)
          padded = padded + 8
          avail = avail + 8
        end
      end
    end

    ll_entry = ll_entries[ll_state]
    of_entry = of_entries[of_state]
    ml_entry = ml_entries[ml_state]
    ll_code = ll_entry.bit_and(255)
    of_code = of_entry.bit_and(255)
    ml_code = ml_entry.bit_and(255)
    avail = avail - of_code
    of_value = 1.shift_left(of_code) + acc.shift_right(avail).bit_and(masks[of_code])
    width = MATCH_LENGTH_BITS[ml_code]
    avail = avail - width
    match_length = MATCH_LENGTH_BASES[ml_code] + acc.shift_right(avail).bit_and(masks[width])
    if avail < 42
      while avail < 56
        if pos >= first
          acc = acc.shift_left(8).bit_or(block[pos])
          pos = pos - 1
          avail = avail + 8
        else
          acc = acc.shift_left(8)
          padded = padded + 8
          avail = avail + 8
        end
      end
    end

    width = LITERAL_LENGTH_BITS[ll_code]
    avail = avail - width
    literal_length = LITERAL_LENGTH_BASES[ll_code] + acc.shift_right(avail).bit_and(masks[width])
    if i + 1 < total
      width = ll_entry.shift_right(8).bit_and(255)
      avail = avail - width
      ll_state = ll_entry.shift_right(16) + acc.shift_right(avail).bit_and(masks[width])
      width = ml_entry.shift_right(8).bit_and(255)
      avail = avail - width
      ml_state = ml_entry.shift_right(16) + acc.shift_right(avail).bit_and(masks[width])
      width = of_entry.shift_right(8).bit_and(255)
      avail = avail - width
      of_state = of_entry.shift_right(16) + acc.shift_right(avail).bit_and(masks[width])
    end

    offset = of_value - 3
    if of_value > 3
      rep3 = rep2
      rep2 = rep1
      rep1 = offset
    else
      index = of_value
      if literal_length == 0
        index = of_value + 1
      end

      if index == 1
        offset = rep1
      elsif index == 2
        offset = rep2
        rep2 = rep1
        rep1 = offset
      elsif index == 3
        offset = rep3
        rep3 = rep2
        rep2 = rep1
        rep1 = offset
      else
        offset = rep1 - 1
        return Errors.malformed("a repeated offset of 0") if offset == 0

        rep3 = rep2
        rep2 = rep1
        rep1 = offset
      end
    end

    if literal_length > literals.size - used
      return Errors.malformed("#{literal_length} literals, #{literals.size - used} left")
    end

    if produced - base + literal_length + match_length > block_max
      return Errors.malformed("a block that writes over #{block_max} bytes")
    end

    if offset > produced + literal_length
      return Errors.malformed("offset #{offset} over the #{produced + literal_length} bytes written")
    end

    return Errors.malformed("offset #{offset} over the window #{window}") if offset > window

    if literal_length > 0 and offset >= literal_length + match_length
      # The match lies before the literals: one append for both.
      piece = History.match(history, offset - literal_length, match_length)
      history = History.append(history, literals.slice(used, literal_length) + piece)
    else
      if literal_length > 0
        history = History.append(history, literals.slice(used, literal_length))
      end

      history = History.append(history, History.match(history, offset, match_length))
    end

    used = used + literal_length
    produced = produced + literal_length + match_length
  end

  return Errors.malformed("the sequence bits do not end with the last sequence") if pos >= first or avail != padded

  rest = literals.size - used
  if history.produced - base + rest > limits.block_max
    return Errors.malformed("a block that writes over #{limits.block_max} bytes")
  end

  ok(
    state.with(
      literal_lengths: some(plan.literal_lengths),
      offsets: some(plan.offsets),
      match_lengths: some(plan.match_lengths),
      rep1: rep1,
      rep2: rep2,
      rep3: rep3,
      history: History.append(history, literals.slice(used, rest)),
    ),
  )
end

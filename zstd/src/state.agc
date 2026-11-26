## What the blocks of a frame leave for the next one.

import Fse from "fse"
import Huffman from "huffman"
import History from "history"

## The tables and the repeated offsets that a block may reuse, and the output so far.
struct State
  huffman: Optional[Huffman.Table]
  literal_lengths: Optional[Fse.Table]
  offsets: Optional[Fse.Table]
  match_lengths: Optional[Fse.Table]
  rep1: Int
  rep2: Int
  rep3: Int
  history: History.History
end

## The sizes that bound a frame: the window that a match may reach back over, and the most a block may write.
struct Limits
  window: Int
  block_max: Int
end

## The state at the start of a frame.
def fresh() -> State
  State(
    huffman: none,
    literal_lengths: none,
    offsets: none,
    match_lengths: none,
    rep1: 1,
    rep2: 4,
    rep3: 8,
    history: History.empty(),
  )
end

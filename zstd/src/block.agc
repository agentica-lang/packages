## A compressed block: its literals, then its sequences.

import Literals from "literals"
import Sequences from "sequences"
import State from "state"

## Decodes `block` after `state` and returns the state it leaves.
def decode(state: State.State, block: Bytes, limits: State.Limits) -> Result[State.State]
  section = try Literals.read(block, state.huffman, limits.block_max)
  Sequences.run(state.with(huffman: section.table), section.bytes, block, section.next, limits)
end

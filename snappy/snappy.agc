import Decode from "src/decode"
import Encode from "src/encode"

## Decodes a raw Snappy block; an `error` of kind `snappy.malformed` when the input is not a valid block.
def decompress(data: Bytes) -> Result[Bytes] = Decode.decompress(data)

## Encodes `data` as a raw Snappy block with a greedy matcher.
def compress(data: Bytes) -> Bytes = Encode.compress(data)

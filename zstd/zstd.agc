import Frame from "src/frame"

## Decodes the frames of `data` into one `Bytes`. An `error` of kind `zstd.malformed` when the input is not valid,
## `zstd.unsupported` for a frame that needs a dictionary and `zstd.too_large` when the content is over `max_size`.
def decompress(data: Bytes, max_size: Int) -> Result[Bytes] = Frame.decode(data, max_size)

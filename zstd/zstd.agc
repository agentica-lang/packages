import Frame from "src/frame"

## Decodes the frames of `data` into one `Bytes`. An `error` of kind `zstd.malformed` when the input is not valid,
## `zstd.unsupported` for a frame whose dictionary ID is not zero or whose window is over 2 GiB, and `zstd.too_large`
## when the content is over `max_bytes`. With `verify` false the 4 checksum bytes of a frame must still be there, but
## are not compared with the content, which saves the time of XXH64.
def decompress(data: Bytes, max_bytes: Int, verify: Bool = true) -> Result[Bytes]
  Frame.decode(data, max_bytes, verify)
end

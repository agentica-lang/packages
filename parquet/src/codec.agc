## The codecs of a page body. Each gives exactly the uncompressed size that the page header names, or an error.

import Errors from "errors"
import Snappy from "pkg/snappy/snappy"
import Thrift from "thrift"

## The body of a page after its codec, which must come to exactly `size` bytes.
def expand(codec: Int, raw: Bytes, size: Int) -> Result[Bytes]
  if codec == UNCOMPRESSED
    sized(raw, size)
  elsif codec == SNAPPY
    snappy(raw, size)
  elsif codec == GZIP
    gzip(raw, size)
  else
    Errors.unsupported("the codec #{codec}")
  end
end

private

UNCOMPRESSED = 0
SNAPPY = 1
GZIP = 2

def sized(bytes: Bytes, size: Int) -> Result[Bytes]
  return Errors.malformed("a page of #{bytes.size} bytes, not #{size}") if bytes.size != size

  ok(bytes)
end

# The block says its own length first; a length other than the page's is refused before anything is decoded.
def snappy(raw: Bytes, size: Int) -> Result[Bytes]
  preamble = try Thrift.varint(raw, 0)
  return Errors.malformed("a snappy page of #{preamble.value} bytes, not #{size}") if preamble.value != size

  case Snappy.decompress(raw)
    ok(expanded) -> sized(expanded, size)
    error(_) -> Errors.malformed("a snappy page that does not decode")
  end
end

# `Zlib.gunzip` holds a megabyte at most, so the page goes through the streaming step, which checks `max_bytes` as it
# goes. An empty page has no gzip member worth reading (the step refuses a cap of 0).
def gzip(raw: Bytes, size: Int) -> Result[Bytes]
  return sized("".bytes, size) if size == 0

  case [raw].lazy.gunzip(size).to_a
    ok(chunks) -> sized(Bytes.concat(chunks), size)
    error(_) -> Errors.malformed("a gzip page that does not expand to #{size} bytes")
  end
end

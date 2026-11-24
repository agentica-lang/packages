---
title: snappy
description: The Snappy raw block format in pure Agentica. Decode a block, refusing every malformed one with an error, and encode a block with a greedy matcher.
---

`snappy` reads and writes raw Snappy blocks, the format of [google/snappy](https://github.com/google/snappy/blob/main/format_description.txt) without the framing format. It is the default codec of Parquet, so most datasets on Hugging Face need it to be read. It is pure Agentica and does no I/O: give it the bytes.

## Install

Needs Agentica 0.37.0. Once the first release is tagged, add it to a project with an `agentica.toml`:

```sh
agentica add snappy https://github.com/agentica-lang/packages --tag snappy-0.1.0 --subdir snappy
```

The dependency entry is:

```toml
snappy = { git = "https://github.com/agentica-lang/packages", tag = "snappy-0.1.0", subdir = "snappy" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/snappy/CHANGELOG.md).

## Example

```agentica
import Snappy from "pkg/snappy/snappy"

def main() -> Void
  text = "abcabcabcabcabcabc".bytes
  block = Snappy.compress(text)
  IO.puts("#{text.size} bytes became #{block.size}: #{OpenSSL.Digest.hexencode(block)}")
  case Snappy.decompress(block)
    ok(back) -> IO.puts(back.scrub)
    error(e) -> IO.puts(e.message)
  end
end
```

```output
18 bytes became 8: 12086162633a0300
abcabcabcabcabcabc
```

## API

### `Snappy.decompress(data: Bytes) -> Result[Bytes]`

Decodes a raw block: the length preamble, then literals and copies with one, two or four byte offsets. The data has the length of the preamble, and an error otherwise.

A malformed block is an `error` of kind `snappy.malformed`, with the byte where it went wrong in its message: a preamble that is cut or longer than five bytes, a length over 4294967295, a literal or a copy that runs past the end, an offset of 0 or one before the start of the data, and output that is longer or shorter than the preamble says. A block never reads past its end, so a damaged block is an error and never a crash.

```agentica
import Snappy from "pkg/snappy/snappy"

def main() -> Void
  block = OpenSSL.Digest.hexdecode("12086162633a0300").unwrap!
  case Snappy.decompress(block)
    ok(data) -> IO.puts(data.scrub)
    error(e) -> IO.puts(e.message)
  end

  case Snappy.decompress(OpenSSL.Digest.hexdecode("0500610100").unwrap!)
    ok(data) -> IO.puts(data.scrub)
    error(e) -> IO.puts("#{e.kind}: #{e.message}")
  end
end
```

```output
abcabcabcabcabcabc
snappy.malformed: snappy: copy offset 0 at byte 3
```

### `Snappy.compress(data: Bytes) -> Bytes`

Encodes `data` as one raw block. A greedy matcher looks up the last earlier occurrence of each 4-byte word, writes a copy for a match of 4 bytes or more, and literals for the rest. A copy takes the shortest form that fits its length and offset: two bytes for a length of 4 to 11 at an offset below 2048, three bytes below 65536, five bytes otherwise. `decompress` reads every block that `compress` writes back unchanged.

```agentica
import Snappy from "pkg/snappy/snappy"

def main() -> Void
  block = Snappy.compress("abcabcabcabcabcabc".bytes)
  IO.puts(OpenSSL.Digest.hexencode(block))
  IO.puts(OpenSSL.Digest.hexencode(Snappy.compress("".bytes)))
end
```

```output
12086162633a0300
00
```

## Not in this version

The framing format (`.sz` streams with their CRC32C checks), and a limit on the output size. A copy of up to 64 bytes costs as little as 3 bytes of block, so a small untrusted block can expand about twenty times: limit its size before you decode it.

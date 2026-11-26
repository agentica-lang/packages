---
title: zstd
description: A Zstandard (RFC 8878) decoder in pure Agentica. It reads every kind of block, concatenated and skippable frames and the XXH64 checksum, refuses a hostile input with an error, and takes a limit on the size of the output.
---

`zstd` reads [Zstandard](https://datatracker.ietf.org/doc/html/rfc8878) frames: raw, RLE and compressed blocks, with Huffman literals (one or four streams, or the table of the block before) and FSE sequences (the predefined tables, one repeated symbol, a table in the block, or the table of the block before). It is pure Agentica and does no I/O: give it the bytes. It is the codec that many Parquet files use. There is no compressor.

## Install

Needs Agentica 0.37.0. Add it with the prefixed tag of the release, in a project with an `agentica.toml`:

```sh
agentica add zstd https://github.com/agentica-lang/packages --tag zstd-0.1.0 --subdir zstd
```

The dependency entry is:

```toml
zstd = { git = "https://github.com/agentica-lang/packages", tag = "zstd-0.1.0", subdir = "zstd" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/zstd/CHANGELOG.md).

## Example

```agentica
import Zstd from "pkg/zstd/zstd"

def main() -> Void
  frame = OpenSSL.Digest.hexdecode("28b52ffd0058050200340374686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e20736c656570730300bd0809e0c40ce39865").unwrap!
  case Zstd.decompress(frame, 1_000_000)
    ok(data) -> IO.puts("#{frame.size} bytes became #{data.size}: #{data.scrub.slice(0, 30)}")
    error(e) -> IO.puts(e.message)
  end
end
```

```output
73 bytes became 198: the quick brown fox jumps over
```

## API

### `Zstd.decompress(data: Bytes, max_size: Int) -> Result[Bytes]`

Decodes every frame of `data` and joins their content in order. A skippable frame holds nothing for the decoder and adds nothing. A frame may carry the size of its content, a checksum of it, or neither: the size must match what the blocks write, and the checksum (XXH64, its low 32 bits) must match the content, or the frame is refused.

`max_size` is the most bytes the content of all the frames may have, and it is required: a frame of a few bytes can write 128 KiB or more. A frame that says it holds more than `max_size`, or whose blocks write more, is refused before the bytes are built.

The errors have a kind each, which a caller tests and never the message text:

- `zstd.malformed`: the input is not valid. An empty input, bytes that start no frame, a header or a block cut short, a reserved bit or block type, a block over 128 KiB or over the window, a table that does not add up, a match that reaches back past the start of the frame or past the window, literals or sequences that do not fit their block, and a size or a checksum that does not match. The message names the byte or the part that went wrong.
- `zstd.unsupported`: a frame that needs a dictionary, or has a window over 2 GiB.
- `zstd.too_large`: the content is over `max_size`.

A damaged input is an error and never a crash: each offset, length and count is checked before it is used, so a hostile input also cannot make the decoder read or write past its data or loop for long. The work is linear in the input and the output.

```agentica
import Zstd from "pkg/zstd/zstd"

def main() -> Void
  frame = OpenSSL.Digest.hexdecode("28b52ffd0058050200340374686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f672e20736c656570730300bd0809e0c40ce39865").unwrap!
  cut = frame.take(40)
  with_dictionary = OpenSSL.Digest.hexdecode("28b52ffd210500010000").unwrap!
  for input in [cut, with_dictionary, frame]
    case Zstd.decompress(input, 100)
      ok(data) -> IO.puts("#{data.size} bytes")
      error(e) -> IO.puts(e.kind)
    end
  end
end
```

```output
zstd.malformed
zstd.unsupported
zstd.too_large
```

## What it checks

Everything RFC 8878 asks a decoder to check, and the frame as a whole. It is stricter than the reference `zstd` in one place: a Huffman stream that has bits left over, or that is read past its start, is refused, where `zstd` accepts it and gives data that depends on how it reads. Every other damaged frame that `zstd` refuses, this refuses; and from every damaged frame that both accept, it reads the same data.

## Speed

The decoder runs on the VM, so it is far slower than the C `zstd`: expect a few megabytes a second, and less for frames with a checksum, since XXH64 does its 64-bit arithmetic in `Int` pieces. A Parquet page is decoded in the time it takes to read it.

## Not in this version

Dictionaries (a frame with a dictionary ID is refused with `zstd.unsupported`), the streaming API, and a compressor.

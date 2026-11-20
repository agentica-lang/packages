---
title: hpack
description: An Agentica codec for HTTP/2 header blocks with a stateful HPACK decoder and a stateless encoder.
---

`hpack` reads and writes complete header blocks in [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html) format. Each field carries its name and value as bytes. Field order, duplicates, and the never-indexed flag survive decoding and re-encoding.

## Install

Needs Agentica 0.35.0. Once the first release is tagged, add it to a project with an `agentica.toml`:

```sh
agentica add hpack https://github.com/agentica-lang/packages --tag hpack-0.1.0 --subdir hpack
```

The dependency entry is:

```toml
hpack = { git = "https://github.com/agentica-lang/packages", tag = "hpack-0.1.0", subdir = "hpack" }
```

## Example

```agentica
import Hpack from "pkg/hpack/hpack"

def main() -> Void
  headers = [
    Hpack.Header(name: ":method".bytes, value: "GET".bytes),
    Hpack.Header(name: ":path".bytes, value: "/".bytes),
  ]
  block = Hpack.encode(headers).unwrap!
  decoded = Hpack.decode(Hpack.decoder(), block).unwrap!
  for field in decoded.headers
    IO.puts("#{field.name.scrub} #{field.value.scrub}")
  end
end
```

```output
:method GET
:path /
```

## API

- `Header(name: Bytes, value: Bytes, never_indexed: Bool = false)` is one field. Set `never_indexed` for sensitive fields and preserve it when forwarding a decoded field.
- `decoder() -> DecoderState` creates an empty table with a capacity of 4096 bytes. Keep one decoder state for the incoming direction of each connection and feed it completed blocks in wire order across all streams.
- `set_decoder_limit(state, max_table_size) -> Result[DecoderState]` takes the effective `SETTINGS_HEADER_TABLE_SIZE` after the HTTP/2 layer processes the peer's acknowledgment. Apply each effective change in order. A pending reduction must be satisfied by the first table size update of the next block, even if the allowed size was subsequently raised.
- `decode(state, block, max_header_list_size = 65536) -> Result[DecodedBlock]` returns `headers` and the next `state`. The list budget charges 32 bytes plus the decoded name and value sizes for each field. A rejected block leaves the supplied state intact. Close the HTTP/2 connection on a block decoding error, including a header list limit error, because subsequent blocks can depend on table changes from the rejected block.
- `encode(headers) -> Result[Bytes]` starts each block with a dynamic table size update to zero. It emits exact static table matches as indexed fields and other fields as raw literals, using a static name index when available. A never-indexed field always uses its literal representation.

The HTTP/2 layer assembles blocks from frames, handles settings and stream state, and validates pseudo-headers and HTTP field semantics.

The static table and Huffman trie derive from appendices A and B of RFC 7541. The trie starts at index zero. Each node is a pair of edges for bits zero and one. Nonnegative edges point to the next pair. A negative edge represents the symbol whose value is the edge's negation minus one.

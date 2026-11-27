---
title: The wire format
description: What two cluster nodes write on a connection, protocol version 1, so that another program can read it.
weight: 2
---

A connection is a TCP stream. Each side first writes the 6 bytes of the preamble, then frames.

```text
preamble   "AGCN" 0x00 0x01     the magic, and the major version of the protocol (1)
frame      u32 length | u8 kind | body
```

The length is big-endian, and it counts the kind and the body, not itself. It is never 0. A reader checks the length against its limit before it reads the body: 1 MiB by default, and a frame over it is `cluster.too_large`. A preamble that is not these 6 bytes, such as an HTTP request or another major version, is `cluster.protocol`, and the socket is closed at once.

The body is the [CBOR](https://www.rfc-editor.org/rfc/rfc8949) of a struct, as `Term.encode` writes it: a map from the name of the field to its value, with the shortest head of each item. A key that the reader does not know is ignored, and a field that is missing is an error, so a field is only ever added with a new kind.

The format evolves by the major byte of the preamble and by new kinds from 64 to 127, which an older node skips.

## Kinds

| Kind | Name | Body |
|---|---|---|
| 5 | mail | `{mailbox: text, body: bytes}`: `body` is the `Term.encode` of the value, which the mailbox of the receiving node decodes |
| 6 | ping | `{}` |
| 7 | pong | `{}` |
| 8 | bye | `{reason: text}`: the node leaves on purpose |

The kinds 1 to 4 are kept for the handshake with the cookie, which comes in a later release. A kind from 64 to 127 is ignored, so a later version can add a message that an older one skips. Any other kind that is not in the table is `cluster.protocol`.

A mailbox name has 1 to 255 bytes. A body that is not the CBOR of its kind, with bytes after the map, or a frame that has more or fewer bytes than its length says is `cluster.protocol`.

## Example

A ping is 6 bytes, and a mail for the mailbox `jobs` with the text `hi` is 27:

```text
00 00 00 02 06 a0
00 00 00 17 05 a2 67 6d 61 69 6c 62 6f 78 64 6a 6f 62 73 64 62 6f 64 79 42 68 69
```

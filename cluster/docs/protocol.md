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
| 1 | hello | `{node: text, nonce: bytes}`: the client's name and a nonce of 32 bytes |
| 2 | challenge | `{node: text, nonce: bytes, proof: bytes}`: the server's name, a nonce of 32 bytes and its proof of 32 bytes |
| 3 | proof | `{proof: bytes}`: the client's proof of 32 bytes |
| 4 | welcome | `{}` |
| 5 | mail | `{mailbox: text, body: bytes}`: `body` is the `Term.encode` of the value, which the mailbox of the receiving node decodes |
| 6 | ping | `{}` |
| 7 | pong | `{}` |
| 8 | bye | `{reason: text}`: the node leaves on purpose |

A kind from 64 to 127 is ignored, so a later version can add a message that an older one skips. Any other kind that is not in the table is `cluster.protocol`.

A mailbox name has 1 to 255 bytes. A body that is not the CBOR of its kind, with bytes after the map, or a frame that has more or fewer bytes than its length says is `cluster.protocol`.

## The handshake

The client opens with `hello`, and the two sides prove that they know the cookie before any other kind is allowed. The cookie is never sent.

1. The client writes `hello` with its name and a new nonce `nc`.
2. The server writes `challenge` with its name, a new nonce `ns` and its proof.
3. The client checks that proof, and writes `proof` with its own.
4. The server checks it, and writes `welcome`. The link is up.

A proof is the HMAC-SHA256, with the cookie as the key, of this transcript: the Term CBOR of a map of the fields `protocol` (the text `agcn1`), `role` (the text `server` for the proof of the server, `client` for the proof of the client), `client` and `server` (the two names), `client_nonce` and `server_nonce` (bytes), in that order. The role keeps a proof of one side from being sent back as the proof of the other. The nonces are new for each connection, so what a stranger saw on an earlier one proves nothing. A proof is compared in constant time, and a proof that does not match is `cluster.refused`.

A node name is a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`. The client and the server need different names. A cookie has at least 16 bytes.

## Example

A ping is 6 bytes, and a mail for the mailbox `jobs` with the text `hi` is 27:

```text
00 00 00 02 06 a0
00 00 00 17 05 a2 67 6d 61 69 6c 62 6f 78 64 6a 6f 62 73 64 62 6f 64 79 42 68 69
```

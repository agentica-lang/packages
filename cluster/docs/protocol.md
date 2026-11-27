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

The length is big-endian, and it counts the kind and the body, not itself. It is never 0. A reader checks the length against its limit before it reads the body: 1,048,572 bytes by default (and at most, so that a frame and its length go out in one write of 1 MiB), and a frame over it is `cluster.too_large`. A preamble that is not these 6 bytes, such as an HTTP request or another major version, is `cluster.protocol`, and the socket is closed at once.

The body is the [CBOR](https://www.rfc-editor.org/rfc/rfc8949) of a struct, as `Term.encode` writes it: a map from the name of the field to its value, with the shortest head of each item. A key that the reader does not know is ignored, and a field that is missing is an error, so a field is only ever added with a new kind.

The format evolves by the major byte of the preamble and by new kinds from 64 to 127, which an older node skips (`groups`, 64, is the first).

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
| 8 | bye | `{reason: text}`: the node ends the link on purpose. The reason `leave` says that the node leaves the cluster: the reader drops it as left, and does not dial it again |
| 64 | groups | `{version: int, groups: [{group: text, mailbox: text}]}`: all the memberships of the sender, and the number of its last change |

A kind from 65 to 127 is ignored, so a later version can add a message that an older one skips. Any other kind that is not in the table is `cluster.protocol`.

A mailbox name has 1 to 255 bytes. A body that is not the CBOR of its kind, with bytes after the map, or a frame that has more or fewer bytes than its length says is `cluster.protocol`.

## The handshake

The client opens with `hello`, and the two sides prove that they know the cookie before any other kind is allowed. The cookie is never sent.

1. The client writes `hello` with its name and a new nonce `nc`.
2. The server writes `challenge` with its name, a new nonce `ns` and its proof.
3. The client checks that proof, and writes `proof` with its own.
4. The server checks it, and writes `welcome`. The link is up.

A proof is the HMAC-SHA256, with the cookie as the key, of this transcript: the Term CBOR of a map of the fields `protocol` (the text `agcn1`), `role` (the text `server` for the proof of the server, `client` for the proof of the client), `client` and `server` (the two names), `client_nonce` and `server_nonce` (bytes), in that order. The role keeps a proof of one side from being sent back as the proof of the other. The nonces are new for each connection, so what a stranger saw on an earlier one proves nothing. A proof is compared in constant time.

Rules for a node that reads these frames:

- Before `welcome`, only the frame that comes next in the list above is allowed. A `mail`, a `ping`, a frame of an ignored kind or any other frame out of order is `cluster.protocol`, and the socket is closed.
- A frame is at most 256 bytes before `welcome` (the biggest one of the handshake has less than 200). The length is checked before the body is read, so a stranger cannot make a node read more. After `welcome` the limit of the connection applies.
- The handshake has a deadline (the `connect_ms` of the options, 5 seconds by default). A connection that has not finished by then is closed.
- A proof that does not match closes the socket at once, with no other frame, so a wrong guess learns nothing from the answer. The error is `cluster.refused`.
- A node name is a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`. The two names differ, and so do the two nonces (32 bytes each). A client that dialed a node by its name uses that name in the transcript, never the one in the challenge, so a node that answers under another name fails the proof.
- A cookie has 16 bytes at least. That is a floor, not a measure of strength: make the cookie a random secret, such as `openssl rand -hex 32`.
- A message about a peer never repeats a name or a text that the peer wrote.

## After the welcome

- Each frame is written with one `TCP.send_bytes` (a frame is at most 1,048,572 bytes, under the 1 MiB that one write takes), which holds the writer lock of the socket for the whole call, so frames that several tasks write to one link (a `ping`, a `pong`, a `mail` from `Cluster.send` or `Cluster.group_send` and a `groups`) never interleave. A write that fails or times out may have sent half a frame, so the node closes the link.
- A `mail` goes to the mailbox that it names; a frame of an ignored kind is skipped; a `bye` ends the link (as left, when its reason is `leave`; the other reasons end it as a closed link).
- A node that has memberships writes `groups` to each peer when a link is kept, and again after each change. It always says all of them, with a number that grows by one at each change, so a frame that is lost or comes twice is harmless: a reader keeps the one with the highest number, and forgets what a peer said when its link ends (a new link starts from nothing). A `groups` that comes from a node that is not linked is not kept, and one that is not a valid body (a version under 1, a name that is not valid, or the same pair twice) is `cluster.protocol`. A node has one writer for each link, which sends the newest `groups` it has, so a change that a later one replaced before it was written is not sent. Every node of a cluster should have the same `max_frame_bytes`, since a frame over the limit of a reader ends the link there.
- Every heartbeat, a node that has heard nothing on a link for half of one writes a `ping`, and every `ping` is answered with a `pong`. Any bytes that arrive are a sign of life, so a link with traffic needs no ping. A link that is silent for 3 heartbeats is closed, and so is one where a `ping` cannot be written in 3 heartbeats. The heartbeat is a choice of each node (`heartbeat_ms`): a peer with a longer one is still answered, but it will take the link for silent if it pings less than every 3 heartbeats of the other.

## What the cookie does not give

The handshake proves that both ends know the cookie when the link opens. It does not make a session key and it does not bind the proofs to the connection, so:

- After `welcome`, frames have no encryption and no integrity. A node between two real nodes can relay the handshake, and then read, change or add frames. On a network that you do not trust, wait for TLS (planned), or keep the nodes on a trusted network.
- The cookie is one secret for the whole cluster. A node that has it can use any name.
- A stranger that saw one proof and the transcript behind it (the names and the nonces are in the clear) can try cookies offline. A random cookie of 32 bytes or more makes that hopeless; a short or guessable one does not.

## Example

A ping is 6 bytes, and a mail for the mailbox `jobs` with the text `hi` is 27:

```text
00 00 00 02 06 a0
00 00 00 17 05 a2 67 6d 61 69 6c 62 6f 78 64 6a 6f 62 73 64 62 6f 64 79 42 68 69
```

A whole handshake, for the nodes `alpha` (the client) and `beta` (the server), the cookie `0123456789abcdef-cookie`, the nonce of the client `000102...1f` (the bytes 0 to 31) and the nonce of the server `646566...83` (the bytes 100 to 131). The transcript of the proof of the server is the Term CBOR of the six fields, with the role `server`:

```text
a6 68 70726f746f636f6c 65 6167636e31          protocol: "agcn1"
   64 726f6c65 66 736572766572                role: "server"
   66 636c69656e74 65 616c706861              client: "alpha"
   66 736572766572 64 62657461                server: "beta"
   6c 636c69656e745f6e6f6e6365 5820 <32 bytes>   client_nonce
   6c 7365727665725f6e6f6e6365 5820 <32 bytes>   server_nonce
```

The proof of the server is `098d13838e49805392f7e8cc2205cdd7a128ff9a484d52ed06703630c9f7f648`. With the role `client` (`66 636c69656e74`) in its place, the proof of the client is `7cfd4793fba3a3380878d326cfcec934954c42143fc63840c2caa604da7674a5`. The four frames, each with its length (after the preamble that both sides wrote):

```text
hello      0000003501a2646e6f646565616c706861656e6f6e63655820000102...1d1e1f
challenge  0000005c02a3646e6f64656462657461656e6f6e636558206465666768...80818283
           6570726f6f665820098d13838e49805392f7e8cc2205cdd7a128ff9a484d52ed06703630c9f7f648
proof      0000002a03a16570726f6f6658207cfd4793fba3a3380878d326cfcec934954c42143fc63840c2caa604da7674a5
welcome    0000000204a0
```

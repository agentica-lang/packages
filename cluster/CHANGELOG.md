# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Needs Agentica 0.39.1.

- Add the wire format of a connection: the preamble `AGCN` and the version, and frames of a length, a kind and a Term CBOR body (ping, pong, bye and mail for a mailbox), read and written as pure functions on `Bytes` that check the length before the body and never halt on bad bytes. The errors are `cluster.protocol` and `cluster.too_large`.
- Add the handshake with the cookie as pure functions: `hello`, `challenge`, `proof` and `welcome` frames, proofs that are the HMAC-SHA256 of a transcript with both names and both nonces and a label for each role (so a proof is never sent back, and an earlier connection proves nothing), a constant-time check, and the rules for a node name and a cookie (16 bytes at least, a floor and not a measure of strength). The errors `cluster.refused` and `cluster.argument` are public.

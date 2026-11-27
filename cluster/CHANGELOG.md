# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- A node that finds its own address by discovery leaves it alone for 10 lookups, and `Cluster.refused` no longer counts a node that dials itself.
- Add `examples/docker-compose.discover.yml`: replicas that find each other by the name of their service.
- Add discovery by DNS: `Options.discover` is a `host:port` whose host is a name with the addresses of the nodes, looked up at start and every `discover_ms` (10 s by default), and each address that the node is not linked with is dialed.

## [0.1.0] - 2026-11-27

Needs Agentica 0.39.1.

- Add the wire format of a connection: the preamble `AGCN` and the version, and frames of a length, a kind and a Term CBOR body (ping, pong, bye and mail for a mailbox), read and written as pure functions on `Bytes` that check the length before the body and never halt on bad bytes. The errors are `cluster.protocol` and `cluster.too_large`.
- Add the handshake with the cookie as pure functions: `hello`, `challenge`, `proof` and `welcome` frames, proofs that are the HMAC-SHA256 of a transcript with both names and both nonces and a label for each role (so a proof is never sent back, and an earlier connection proves nothing), a constant-time check, and the rules for a node name and a cookie (16 bytes at least, a floor and not a measure of strength). The errors `cluster.refused` and `cluster.argument` are public.
- Add the nodes: `Cluster.start` listens (on this machine only, unless `insecure_plaintext`) and dials a list of peers, `Cluster.connect`, `Cluster.nodes`, `Cluster.port`, `Cluster.refused` and `Cluster.stop`. A connection runs the handshake with the cookie: frames in order, 256 bytes at most before the welcome, a deadline, and a silent close for a node that fails it. A peer may be written `name@host:port` to check the name that answers. Two nodes that connect at the same moment keep the link that the smaller name dialed, and a node that dials an address twice at once makes one connection. At most `max_pending` connections are in their handshake at once. New errors `cluster.unreachable` and `cluster.closed`.
- Add mailboxes: `Cluster.register` names a mailbox that takes `Cluster.Delivery` messages (the peer and the bytes of a `Term.encode`), `Cluster.send` writes bytes to a mailbox of a connected peer, and `Cluster.dropped` counts the messages for a mailbox that does not exist or cannot take them. Delivery is at most once. New error `cluster.not_connected`. `max_frame_bytes` is now 1,048,572 at most (and by default), so that a frame goes out in one write. The capacity of the channel of a mailbox is its bound.
- Add heartbeats and events: a quiet link gets a ping every `heartbeat_ms` (1000 by default) and a link that is silent for 3 heartbeats is closed, and `Cluster.watch` tells an address `Event.NodeUp(name)` when a peer is connected and `Event.NodeDown(name)` when its link ends (bye, closed socket or silence).
- Add reconnect: a peer of the list that cannot be reached, or whose link ends, is dialed again after `reconnect_ms` (500 by default), then after twice that and so on up to `reconnect_max_ms` (30 s); the wait starts over when a link is kept, and a peer of the list whose link came in is dialed again too.
- Add reconnect: a peer of the list that cannot be reached, or whose link ends, is dialed again after `reconnect_ms` (500 by default), then after twice that and so on up to `reconnect_max_ms` (30 s); the wait starts over when a link is kept.
- Add `examples/node.agc`, a node that prints `node_up`, `node_down` and the greetings of its peers, and a `docker-compose.yml` with three nodes and a `stranger` with another cookie.

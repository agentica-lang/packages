---
title: cluster
description: Connect Agentica nodes on one host or on several, with a shared cookie, and send messages to named mailboxes (in progress).
category: Networking
keywords: [cluster, node, distributed, cookie, cbor]
---

`cluster` connects Agentica nodes: programs on one machine or on several, each with a name, that send messages to each other and learn when a node goes away. It is a package, with no change in the VM: it runs on `TCP` (and `TLS` later) and on `Term` (CBOR).

The design is decided in [agentica#1834](https://github.com/agentica-lang/agentica/issues/1834) and the plan in [packages#264](https://github.com/agentica-lang/packages/issues/264):

- **Trust:** a shared cookie, for internal networks. The cookie is never sent: each side proves that it knows it with an HMAC of a random value of the other side. Make it a random secret, such as `openssl rand -hex 32`: the least size is 16 bytes, a floor and not a measure of strength. After the handshake the frames are not encrypted (TLS comes later), so keep the nodes on a trusted network. [What the cookie does not give](protocol.md#what-the-cookie-does-not-give).
- **Membership:** a static list of nodes at first. A node keeps one connection to each peer and connects again when it is lost.
- **Messages:** a value goes to a named mailbox of another node, as the bytes of `Term.encode`. The receiver decodes them into its own type with `Term.decode`, so the type is checked where the message arrives and a bad message is an error for that message.
- **Failure:** heartbeats on each connection. A missed deadline or a closed socket is `node_down`, and `node_up` when the node comes back.
- **Delivery:** at most once. The package never retries.

## Status

Not released yet. The package grows one piece at a time, and `cluster-0.1.0` comes when a node can report `node_down` too. Today a node can start, connect to the nodes of its list, prove the cookie, know its [peers](protocol.md) and send bytes to the mailboxes of its peers. It does not retry yet: a peer that is down when the node starts is not dialed again, and a link that is lost is not dialed again (reconnecting comes with the heartbeats).

## Example

Two nodes in one program, which is how the specs run them (nodes of different programs on one host or on several work the same). A node is started from `main` or from a supervisor, since its actor and its tasks end with the task that started it.

```agentica
import Cluster from "pkg/cluster/cluster"

def main() -> Void
  cookie = "a-random-secret-of-16-bytes-or-more"
  alpha = Cluster.start(Cluster.Options(name: "alpha", cookie: cookie)).unwrap!
  beta = Cluster.start(Cluster.Options(name: "beta", cookie: cookie)).unwrap!
  puts(Cluster.connect(beta, "127.0.0.1:#{Cluster.port(alpha)}").unwrap!)
  puts(Cluster.nodes(beta))
  _ = Cluster.stop(beta, 1000)
  _ = Cluster.stop(alpha, 1000)
end
```

```output
alpha
["alpha"]
```

## Messages

A node registers a mailbox by name, and a peer sends bytes to that name. The bytes are what `Term.encode` wrote for a value, and the receiver turns them into its own type with `Term.decode`, so the type is checked where the message arrives: bytes that do not fit are an error for that message, and the link and the node go on.

```agentica
import Cluster from "pkg/cluster/cluster"

struct Job
  id: Int
  name: String
end

def main() -> Void
  cookie = "a-random-secret-of-16-bytes-or-more"
  alpha = Cluster.start(Cluster.Options(name: "alpha", cookie: cookie)).unwrap!
  beta = Cluster.start(Cluster.Options(name: "beta", cookie: cookie)).unwrap!
  inbox: Channel[Cluster.Delivery] = Channel.new(64)
  Cluster.register(beta, "jobs", inbox.address, ->(delivery) { delivery }).unwrap!
  _ = Cluster.connect(alpha, "127.0.0.1:#{Cluster.port(beta)}").unwrap!

  body = Term.encode(Job(id: 7, name: "compile")).unwrap!
  Cluster.send(alpha, "beta", "jobs", body).unwrap!

  delivery = inbox.recv(2000).unwrap!
  job = Term.decode(delivery.body, Job).unwrap!
  puts("#{delivery.from} sent job #{job.id} #{job.name}")
  _ = Cluster.stop(alpha, 1000)
  _ = Cluster.stop(beta, 1000)
end
```

```output
alpha sent job 7 compile
```

`send` takes `Bytes` and not a value of any type because `Term.encode` and `Term.decode` need the concrete type at the call (a generic function cannot pass its `T` to them: `CHECK-NOT-ENCODABLE`). So the sender calls `Term.encode` on its value, and the receiver calls `Term.decode` with its type. Put a `version` field in a message that will change, as the page of `Term` says: adding a field breaks old data.

Delivery is at most once: `send` returns once the bytes are in the socket, with no reply and no retry, and a message for a mailbox that does not exist, or that cannot take it at once, is dropped and counted (`dropped`). The capacity of the channel (64 above) is the bound of the mailbox: when it is full the node drops, so a slow reader loses messages and does not slow the link. An unbounded channel (`Channel.new()`) never drops and can fill the memory. The messages that one task sends to one peer arrive in the order they were sent, while the link stays up.

## API

### Cluster.start(options: Cluster.Options) -> Result[Cluster.Node]

Starts a node: it listens on `host` and `port` and dials each of `peers` in the background. `Options` has `name` (a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`), `cookie` (16 bytes or more), `host` (`127.0.0.1`), `port` (0: the system picks one), `peers` (a list of `host:port` or `name@host:port`), `connect_ms` (5000, at most 600000: the time that a dial has to connect and shake hands, and that a connection that comes in has for its handshake), `max_pending` (128: how many connections may be in their handshake at once; a new one over that is closed at once), `max_frame_bytes` (1,048,572 bytes, which is also the most: a frame and its length go out in one write of 1 MiB) and `insecure_plaintext` (false). Plain TCP is only for this machine: a `host` or a peer that is not on it is `cluster.argument` unless `insecure_plaintext` is true, and then the network must be one that you trust (the frames have no encryption). A peer written `name@host:port` must answer under that name. A peer listed twice is dialed once. `localhost` is loopback because the hosts file of the machine says so: a name that the hosts file changes is as trusted as the file.

### Cluster.connect(node: Cluster.Node, address: String) -> Result[String]

Connects to `host:port` or `name@host:port` and waits for the handshake. It gives the name of the peer, or an error: `cluster.unreachable`, `cluster.refused`, `cluster.closed` or `cluster.protocol`. A node that is already connected to that address, or is dialing it, answers with the name of the peer and makes no second connection.

### Cluster.nodes(node: Cluster.Node) -> List[String]

The names of the peers that are connected, in order.

### Cluster.port(node: Cluster.Node) -> Int

The port that the node listens on.

### Cluster.refused(node: Cluster.Node) -> Int

How many handshakes the node refused: a peer that did not know the cookie, or that used the name of this node. A stranger that did not speak the protocol is disconnected and not counted.

### Cluster.register(node: Cluster.Node, name: String, address: Address[M], wrap: Fn[Cluster.Delivery, M]) -> Result[Void]

Registers the mailbox `name` (1 to 255 bytes). What a peer sends to it comes to `address` as the `M` that `wrap` makes of a `Delivery` (`from`, `mailbox` and `body`): `->(delivery) { delivery }` for a channel of deliveries, or a variant of the message type of an actor. The node never waits for the address: a message that it cannot put in at once is dropped, so the capacity of the channel is the bound of the mailbox (an unbounded channel never drops and can fill the memory). `wrap` runs in the actor of the node, so it must be pure and cheap. Registering a name again replaces the mailbox. A node that is stopped gives `cluster.closed`.

### Cluster.send(node: Cluster.Node, peer: String, mailbox: String, body: Bytes, timeout_ms: Int = 5000) -> Result[Void]

Sends `body`, the `Term.encode` of a value, to a mailbox of a connected peer. It fails with `cluster.argument` (`timeout_ms` is less than 1), `cluster.not_connected`, `cluster.too_large` (the frame is over `max_frame_bytes`) or `cluster.closed` (the node is stopped, the link broke, or the write took more than `timeout_ms`). A write that times out closes the link, and the peer is down (there is no reconnect yet). A frame over the limit of the receiver ends the whole link there, not only that message: keep `max_frame_bytes` the same on all the nodes. Ok says that the bytes are in the socket, not that the mailbox took them.

### Cluster.dropped(node: Cluster.Node) -> Int

How many messages the node dropped: for a mailbox that does not exist, one that was full, or because the node was too busy to look at them.

### Cluster.stop(node: Cluster.Node, timeout_ms: Int) -> Result[Void]

Stops the listener, the links, the connections that are being dialed and the actor of the node. It waits at most `timeout_ms` for the actor to end, and gives the error of `std/actor` if it does not.

## Two nodes that connect at the same moment

If two nodes connect to each other at the same moment, both keep the link that the node with the smaller name dialed, and drop the other, with no talk between them.

## Errors

An error has a kind that a program tests, never the text.

| Kind | When |
|---|---|
| `cluster.protocol` | the bytes break the wire format: a bad preamble, a frame with no kind, an unknown kind, a body that does not fit its kind, an empty or long mailbox name |
| `cluster.refused` | a node did not prove the cookie, has the name of this node, or answered under another name than the one dialed |
| `cluster.argument` | a bad option, such as a cookie of less than 16 bytes |
| `cluster.not_connected` | `send` to a peer that is not connected now |
| `cluster.unreachable` | nothing answers at the address, or not in time |
| `cluster.closed` | the other side closed the connection or went quiet during the handshake, as a node does to one that fails it |
| `cluster.too_large` | a frame is longer than the limit of the connection (1,048,572 bytes by default, 256 bytes before the handshake ends) |

```agentica
import Cluster from "pkg/cluster/cluster"

def stranger() -> Result[Void] = error("a stranger", kind: Cluster.REFUSED)

def main() -> Void
  case stranger()
    ok(_) -> puts("welcome")
    error(e) -> puts("#{e.is_a?(Cluster.REFUSED)} #{e.is_a?(Cluster.PROTOCOL)} #{e.is_a?(Cluster.ARGUMENT)}")
  end
end
```

```output
true false false
```

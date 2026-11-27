---
title: cluster
description: Connect Agentica nodes on one host or on several, with a shared cookie, and send messages to named mailboxes. This release has the wire format.
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

Not released yet. The package grows one piece at a time, and `cluster-0.1.0` comes when a node can send to a mailbox and report `node_down`. Today a node can start, connect to the nodes of its list, prove the cookie and know its [peers](protocol.md).

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

## API

### Cluster.start(options: Cluster.Options) -> Result[Cluster.Node]

Starts a node: it listens on `host` and `port` and dials each of `peers` in the background. `Options` has `name` (a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`), `cookie` (16 bytes or more), `host` (`127.0.0.1`), `port` (0: the system picks one), `peers` (a list of `host:port` or `name@host:port`), `connect_ms` (5000: the time that a connection has for its handshake), `max_frame_bytes` (1 MiB) and `insecure_plaintext` (false). Plain TCP is only for this machine: a `host` or a peer that is not on it is `cluster.argument` unless `insecure_plaintext` is true, and then the network must be one that you trust (the frames have no encryption). A peer written `name@host:port` must answer under that name.

### Cluster.connect(node: Cluster.Node, address: String) -> Result[String]

Connects to `host:port` or `name@host:port` and waits for the handshake. It gives the name of the peer, or an error: `cluster.unreachable`, `cluster.refused`, `cluster.closed` or `cluster.protocol`. A node that is already connected to that peer keeps one link.

### Cluster.nodes(node: Cluster.Node) -> List[String]

The names of the peers that are connected, in order.

### Cluster.port(node: Cluster.Node) -> Int

The port that the node listens on.

### Cluster.refused(node: Cluster.Node) -> Int

How many handshakes the node refused: a peer that did not know the cookie, or that used the name of this node. A stranger that did not speak the protocol is disconnected and not counted.

### Cluster.stop(node: Cluster.Node, timeout_ms: Int) -> Result[Void]

Stops the listener, the links and the actor of the node.

## Two nodes that connect at the same moment

If two nodes connect to each other at the same moment, both keep the link that the node with the smaller name dialed, and drop the other, with no talk between them.

## Errors

An error has a kind that a program tests, never the text.

| Kind | When |
|---|---|
| `cluster.protocol` | the bytes break the wire format: a bad preamble, a frame with no kind, an unknown kind, a body that does not fit its kind, an empty or long mailbox name |
| `cluster.refused` | a node did not prove the cookie, has the name of this node, or answered under another name than the one dialed |
| `cluster.argument` | a bad option, such as a cookie of less than 16 bytes |
| `cluster.unreachable` | nothing answers at the address, or not in time |
| `cluster.closed` | the other side closed the connection or went quiet during the handshake, as a node does to one that fails it |
| `cluster.too_large` | a frame is longer than the limit of the connection (1 MiB by default, 256 bytes before the handshake ends) |

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

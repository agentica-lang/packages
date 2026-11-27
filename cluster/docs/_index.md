---
title: cluster
description: Connect Agentica nodes on one host or on several, with a shared cookie, and send messages to named mailboxes. This release has the wire format.
category: Networking
keywords: [cluster, node, distributed, cookie, cbor]
---

`cluster` connects Agentica nodes: programs on one machine or on several, each with a name, that send messages to each other and learn when a node goes away. It is a package, with no change in the VM: it runs on `TCP` (and `TLS` later) and on `Term` (CBOR).

The design is decided in [agentica#1834](https://github.com/agentica-lang/agentica/issues/1834) and the plan in [packages#264](https://github.com/agentica-lang/packages/issues/264):

- **Trust:** a shared cookie, for internal networks. The cookie is never sent: each side proves that it knows it with an HMAC of a random value of the other side.
- **Membership:** a static list of nodes at first. A node keeps one connection to each peer and connects again when it is lost.
- **Messages:** a value goes to a named mailbox of another node, as the bytes of `Term.encode`. The receiver decodes them into its own type with `Term.decode`, so the type is checked where the message arrives and a bad message is an error for that message.
- **Failure:** heartbeats on each connection. A missed deadline or a closed socket is `node_down`, and `node_up` when the node comes back.
- **Delivery:** at most once. The package never retries.

## Status

Not released yet. The package grows one piece at a time, and `cluster-0.1.0` comes when a node can connect, send and report `node_down`. Today it has the [wire format](protocol.md): the preamble and the frames of a connection, written and read as pure functions on `Bytes`, and the kinds of the errors that bytes breaking the format give.

## Errors

An error has a kind that a program tests, never the text.

| Kind | When |
|---|---|
| `cluster.protocol` | the bytes break the wire format: a bad preamble, a frame with no kind, an unknown kind, a body that does not fit its kind, an empty or long mailbox name |
| `cluster.too_large` | a frame is longer than the limit of the connection (1 MiB by default) |

```agentica
import Cluster from "pkg/cluster/cluster"

def stranger() -> Result[Void] = error("a stranger", kind: Cluster.PROTOCOL)

def main() -> Void
  case stranger()
    ok(_) -> puts("welcome")
    error(e) -> puts("#{e.is_a?(Cluster.PROTOCOL)} #{e.is_a?(Cluster.TOO_LARGE)}")
  end
end
```

```output
true false
```

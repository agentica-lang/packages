---
title: cluster
description: Connect Agentica nodes on one host or on several, with a shared cookie, and send messages to named mailboxes.
category: Networking
keywords: [cluster, node, distributed, cookie, cbor]
---

`cluster` connects Agentica nodes: programs on one machine or on several, each with a name, that send messages to each other and learn when a node goes away. It is a package, with no change in the VM: it runs on `TCP` (and `TLS` later) and on `Term` (CBOR).

The design is decided in [agentica#1834](https://github.com/agentica-lang/agentica/issues/1834) and the plan in [packages#264](https://github.com/agentica-lang/packages/issues/264):

- **Trust:** a shared cookie, for internal networks. The cookie is never sent: each side proves that it knows it with an HMAC of a random value of the other side. Make it a random secret, such as `openssl rand -hex 32`: the least size is 16 bytes, a floor and not a measure of strength. After the handshake the frames are not encrypted (TLS comes later), so keep the nodes on a trusted network. [What the cookie does not give](protocol.md#what-the-cookie-does-not-give).
- **Membership:** a static list of nodes at first. A node keeps one connection to each peer. A peer of the list that cannot be reached, or whose link ends (also a link that the peer opened), is dialed again after `reconnect_ms`, and after twice that, and so on up to `reconnect_max_ms`, with up to a fifth more so that peers that failed together do not come back together. The wait starts over when a link of that peer is kept, so a peer that shakes hands and drops at once is dialed every `reconnect_ms`. A failed handshake (another cookie, or a name that is not the one written `name@host:port`) is tried again for ever, and `Cluster.refused` grows with each try. A peer connected with `Cluster.connect` is not dialed again unless its address is in the list.
- **Messages:** a value goes to a named mailbox of another node, as the bytes of `Term.encode`. The receiver decodes them into its own type with `Term.decode`, so the type is checked where the message arrives and a bad message is an error for that message.
- **Failure:** heartbeats on each connection. Every heartbeat, a link that has been quiet for half of one gets a ping, and one that is silent for 3 heartbeats is closed. A closed link is `node_down`, unless the peer said that it leaves (`Cluster.leave`), and then it is `node_left`; a link that is up is `node_up`. A [watcher](#clusterwatch) hears them.
- **Delivery:** at most once. The package never retries.

## Install

Needs Agentica 0.39.1 or later. Add it in a project with an `agentica.toml`:

```sh
agentica add cluster https://github.com/agentica-lang/packages --tag cluster-0.1.0 --subdir cluster
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
cluster = { git = "https://github.com/agentica-lang/packages", tag = "cluster-0.1.0", subdir = "cluster" }
```

This release has a static list of nodes, with no TLS yet: keep the nodes on a network that you trust.

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

## Groups

A mailbox of a node can join a group, a name for the mailboxes that do one kind of work. Each node sees the members of a group: its own and the ones of the peers that are connected. A member is a node and a mailbox, and `group_send` sends a message to all of them.

```agentica
import Cluster from "pkg/cluster/cluster"

def main() -> Void
  cookie = "a-random-secret-of-16-bytes-or-more"
  alpha = Cluster.start(Cluster.Options(name: "alpha", cookie: cookie)).unwrap!
  beta = Cluster.start(Cluster.Options(name: "beta", cookie: cookie)).unwrap!
  inbox: Channel[Cluster.Delivery] = Channel.new(64)
  Cluster.register(alpha, "jobs", inbox.address, ->(delivery) { delivery }).unwrap!
  Cluster.group_join(alpha, "workers", "jobs").unwrap!
  _ = Cluster.connect(beta, "127.0.0.1:#{Cluster.port(alpha)}").unwrap!

  deadline = Time.monotonic_ms() + 2000
  while Cluster.group_members(beta, "workers").unwrap!.empty? and Time.monotonic_ms() < deadline
    Task.sleep(10)
  end

  for member in Cluster.group_members(beta, "workers").unwrap!
    puts("#{member.node} #{member.mailbox}")
  end

  reached = Cluster.group_send(beta, "workers", "hello".bytes).unwrap!
  delivery = inbox.recv(2000).unwrap!
  puts("reached #{reached}, #{delivery.from} said #{String.from_bytes(delivery.body).unwrap!}")

  _ = Cluster.stop(beta, 1000)
  _ = Cluster.stop(alpha, 1000)
end
```

```output
alpha jobs
reached 1, beta said hello
```

A node tells its peers all its memberships when a link is kept and after each change, with a number that grows, so what is lost or comes twice does no harm. The memberships of a peer end with its link (`node_down`) and come back when it connects again and says them. The peers learn of a change a moment after the call returns: a read right after a join on another node may not have it yet. A membership stays until `group_leave` or until the node stops, even if the mailbox is registered again. Every node of a cluster should have the same `max_frame_bytes`: all the memberships of a node go in one frame.

## Try it by hand

`examples/node.agc` is one node of a small cluster, set by environment variables (`NODE_NAME`, `NODE_PORT`, `PEERS`, `CLUSTER_COOKIE`, `INSECURE`; the header of the file lists them). It prints `node_up` and `node_down` as its peers come and go, and greets each peer every 2 seconds. Three terminals, from the folder of the package:

```sh
NODE_NAME=node1 NODE_PORT=7101 PEERS=node2@127.0.0.1:7102,node3@127.0.0.1:7103 agentica examples/node.agc
NODE_NAME=node2 NODE_PORT=7102 PEERS=node1@127.0.0.1:7101,node3@127.0.0.1:7103 agentica examples/node.agc
NODE_NAME=node3 NODE_PORT=7103 PEERS=node1@127.0.0.1:7101,node2@127.0.0.1:7102 agentica examples/node.agc
```

Stop `node2` with Ctrl-C: the other two print `node_down node2`. Start it again with the same line: they print `node_up node2`, because each node dials the peers of its list again until they answer. A fourth node with another `CLUSTER_COOKIE` is refused by the nodes that it dials, and prints how many handshakes were refused.

`examples/docker-compose.yml` starts the same three nodes on one network, and a `stranger` with another cookie (`docker compose -f examples/docker-compose.yml up --build`; then `stop node2` and `start node2` to see the events). The compose file and its `examples/Dockerfile` are for people trying the package; the tests do not use them, and they were written without running Docker. The cookie in the compose file (`CLUSTER_COOKIE`, with a default) is an example in plain text: set your own, a random secret such as `openssl rand -hex 32`, before you use it for anything else. The image runs as a user that is not root, and checks the archive of Agentica against its sha256.

To see discovery with no list of peers, two nodes that find each other by `localhost`, which has two addresses (the second one is the IPv6 loopback):

```sh
NODE_NAME=node1 NODE_HOST=127.0.0.1 NODE_PORT=7000 DISCOVER=localhost:7000 DISCOVER_MS=500 agentica examples/node.agc
NODE_NAME=node2 NODE_HOST=::1 NODE_PORT=7000 DISCOVER=localhost:7000 DISCOVER_MS=500 agentica examples/node.agc
```

Each one finds the other, and its own address too, which it leaves alone. `examples/docker-compose.discover.yml` is the same with a service of three replicas that look up the service name (`DISCOVER=node:7000`, and `NAME_FROM_HOSTNAME=1` so that each replica has a name); `up --scale node=5` adds two that the others find within `DISCOVER_MS`. It sets `endpoint_mode: dnsrr` so that the service name answers with each replica, and it was written without running Docker.

## API

### Cluster.start(options: Cluster.Options) -> Result[Cluster.Node]

Starts a node: it listens on `host` and `port` and dials each of `peers` in the background. `Options` has `name` (a lowercase letter, then up to 62 lowercase letters, digits, `_` or `-`), `cookie` (16 bytes or more), `host` (`127.0.0.1`), `port` (0: the system picks one), `peers` (a list of `host:port` or `name@host:port`), `connect_ms` (5000, at most 600000: the time that a dial has to connect and shake hands, and that a connection that comes in has for its handshake), `reconnect_ms` (500) and `reconnect_max_ms` (30000, at most 600000): the wait before a peer of the list is dialed again, and the most that it grows to; a peer that is linked by then is not dialed, `heartbeat_ms` (1000, 10 to 600000: a quiet link gets a ping every heartbeat, and one that is silent for 3 heartbeats is closed; any chunk of a frame that arrives counts as a sign of life, but a ping that cannot be written in 3 heartbeats, because a big send holds the socket or the peer does not read, ends the link too), `max_pending` (128: how many connections may be in their handshake at once; a new one over that is closed at once), `max_frame_bytes` (1,048,572 bytes, which is also the most: a frame and its length go out in one write of 1 MiB) and `insecure_plaintext` (false) and the two options of discovery. Plain TCP is only for this machine: a `host` or a peer that is not on it is `cluster.argument` unless `insecure_plaintext` is true, and then the network must be one that you trust (the frames have no encryption). A peer written `name@host:port` must answer under that name. A peer listed twice is dialed once.

Discovery: `discover` (empty) is a `host:port` whose host is a name that has the addresses of the nodes (A and AAAA records), and `discover_ms` (10000, 50 to 600000) is how often the node looks it up: at start and every `discover_ms`, it dials each address of the answer that it is not linked with, as the answer gives it (an IPv4 or an IPv6 one), so a service name (a DNS name of a service, a headless service) is enough for the nodes to find each other, with no list. A name that is not this machine needs `insecure_plaintext`, as a peer does. A lookup that takes longer than `connect_ms` is given up and tried again at the next period, and a node that stops does not wait for it. A peer that leaves the answer is not dropped: its link ends as it would. A peer of the list is also dialed by discovery when the answer has its address and it is not linked, so it can be dialed more often than `reconnect_ms` says, but at most once per `discover_ms` by discovery. A node that finds its own address in the answer (a service name has the address of every node, its own too) dials it, hears its own hello (a dial puts its nonce in a table of the node, and a hello of this node's name with that nonce is its own dial), and leaves that address alone for 10 lookups (`10 * discover_ms`); after that it dials it again, and an address that is not in an answer any more is forgotten at once. `Cluster.refused` does not count these. Another node that has the name of this one is still refused and counted. The name must answer with the address of each node, not with one address that is shared (a virtual IP, a balancer, a published port): there a dial may reach the node itself at one lookup and another node at the next, which is why the wait ends. The nonce of a hello travels in clear, so a peer that sees it while the dial runs can make the node leave that address alone, at most for that wait. `localhost` is loopback because the hosts file of the machine says so: a name that the hosts file changes is as trusted as the file.

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

### Cluster.group_join(node: Cluster.Node, group: String, mailbox: String) -> Result[Void]

Puts the registered mailbox `mailbox` of this node in the group `group` (1 to 255 bytes, like a mailbox name), and tells the connected peers. Joining twice is one membership. It fails with `cluster.argument` (a name that is not valid, or a mailbox that is not registered on this node), `cluster.too_large` (the memberships of the node do not fit in a frame) or `cluster.closed` (the node is stopped).

### Cluster.group_leave(node: Cluster.Node, group: String, mailbox: String) -> Result[Void]

Takes the mailbox out of the group and tells the peers. A mailbox that is not in the group is not an error.

### Cluster.group_members(node: Cluster.Node, group: String) -> Result[List[Cluster.Member]]

The members of the group, this node's and the connected peers', ordered by node and mailbox. A `Member` has `node` and `mailbox`. A group that nobody joined gives an empty list.

### Cluster.group_send(node: Cluster.Node, group: String, body: Bytes, timeout_ms: Int = 5000) -> Result[Int]

Sends `body` (the bytes of `Term.encode`, as for `send`) to the mailbox of each member of the group, and gives how many it reached. A member counts when its message is written to the link of its peer (or taken by the queue of this node): that does not say that the mailbox took it, since the mailbox may be full or not registered there, or the peer may die after the write. The members of this node go through the queue of the node, and are not counted if it is full. The members of a peer are written to its link one after the other, in the order of `group_members`, and the peers at the same time (at most 64). `timeout_ms` is for all the frames of one peer: a write that fails or times out closes the link, and the members not yet written are not counted, while the other peers are not held (when the time passes between two frames, the link stays open and the rest are not counted). With more than 64 peers the call can take `ceil(peers / 64)` times `timeout_ms`. A peer that is not connected is not counted, and a group with no members gives `0`. It uses the memberships that this node has now, so a peer that joined a moment ago may not get it. Delivery is at most once, as for `send`. It fails with `cluster.argument` (a name that is not valid, or `timeout_ms` is less than 1), `cluster.too_large` (a frame is over `max_frame_bytes`: nothing is sent) or `cluster.closed` (the node is stopped).

### Cluster.watch(node: Cluster.Node, address: Address[M], wrap: Fn[Cluster.Event, M]) -> Result[Void]

Tells `address` when a peer comes or goes, as the `M` that `wrap` makes of an `Event`: `Event.NodeUp(name)` when the first link to a peer is kept, `Event.NodeDown(name)` when that link ends (the socket closed, or it was silent for 3 heartbeats), and `Event.NodeLeft(name)` when the peer said that it leaves with `leave`: that peer is not dialed again, even if it is of the list. A link that replaces another link of the same peer is not an event, and a peer that is already connected when the watch starts is not told. As for a mailbox, `wrap` must be pure and cheap, and an event that the address cannot take at once is missed: the capacity of the channel is the bound. A peer that comes back after `NodeDown` is a new `NodeUp`. There is no way to stop watching, and watching twice gives every event twice. A peer that is already connected when the watch starts is not told: call `watch` first, then `Cluster.nodes`, and take the union. An event that the address has no room for is counted in `Cluster.dropped`, so give the channel room. Two nodes that connect to each other at the same moment may each see `NodeDown` and then `NodeUp` of the other for the link that lost: the last event is the state.

### Cluster.dropped(node: Cluster.Node) -> Int

How many messages the node dropped: for a mailbox that does not exist, one that was full, or because the node was too busy to look at them, and the events that a watcher had no room for.

### Cluster.leave(node: Cluster.Node, timeout_ms: Int = 5000) -> Result[Void]

Leaves the cluster on purpose and stops the node. It tells each peer (a `bye` with the reason `leave`), and the peers drop it with `Event.NodeLeft`, not `NodeDown`, and do not dial it again even if it is in their list: a node that left comes back by dialing a peer (or with `connect`). While it leaves, the node dials nobody and its own watchers hear nothing. It waits at most `timeout_ms` to tell the peers and for the links to end, and then stops as `stop` does; a peer that could not be told sees the link end as a `stop` would, a `node_down`. It fails with `cluster.argument` (`timeout_ms` is less than 1).

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

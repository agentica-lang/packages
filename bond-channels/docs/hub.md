---
title: The hub
description: The options of the hub and of the mount, the limits, stats, disconnecting a person, and stopping the hub.
weight: 3
---

## Start and stop

`Channels.start_hub(options)` starts the hub. It is one task that holds the topics and sends the broadcasts, plus a ticker for the pings. It returns a `Result[Channels.Hub]`.

`Channels.stop_hub(hub)` ends it, and the ticker. Every broadcast after it fails with "closed". Its connections are told to reconnect (`disconnect` with `reconnect: true`, then close 1001) within 2 seconds, and a new connection is refused the same way, without a `welcome`. A hub that crashes does the same.

`Channels.HubOptions` has two fields:

| Field | Default | What it is |
|---|---|---|
| `broadcast_wait_ms` | 5000 | how long a broadcast waits for room in the inbox of the hub (0 or more) |
| `beat_ms` | 3000 | the Action Cable ping (1 or more), as Rails has it |

`start_hub` returns an `error` for a `beat_ms` under 1 or a negative `broadcast_wait_ms`. The hub whose inbox stays full for `broadcast_wait_ms` refuses a new connection with `reconnect: true` and the close code 1013 ("the hub is busy").

## Mount

`Channels.mount(app, path, hub, options)` adds the cable WebSocket at `path` (use `"/cable"`, the one that the clients expect). It returns a `Result[Bond.App]`.

`Channels.MountOptions`:

| Field | Default | What it is |
|---|---|---|
| `connect` | none | gives the [identity](channels.md) of the person, or an `error` |
| `handlers` | none | the channel names of the client, mapped to their [handlers](channels.md) |
| `allowed_origins` | `[]` | the origins that may connect, as in `Bond.websocket` |
| `inbox` | 256 | the frames queued for one connection (1 or more); a connection with a full inbox is dropped |
| `idle_ms` | 120000 | a peer silent for this long is closed; 0 turns it off |
| `max_message_bytes` | 65536 | a client frame over this closes the connection with 1009 |

`mount` returns an `error` for options that cannot work: an `inbox` or `max_message_bytes` under 1, a negative `idle_ms`, or an `idle_ms` that is not more than the `beat_ms` of the hub (the WebSocket ping that keeps a quiet client could never come in time). The two kinds of options are different records, so a field given to the wrong one does not compile.

A WebSocket holds one of the `max_connections` of the Bond server for its whole life. Set it above the number of clients plus the number of posters (`Bond.start_with(app, host, port, HTTP.ServerOptions(max_connections: 1024))`).

## Broadcasts

`Channels.broadcast_text(hub, topic, text)` sends text (Turbo Stream HTML) to the subscribers of `topic`, as a JSON string. `Channels.broadcast_json(hub, topic, value)` sends a JSON value.

A broadcast that cannot be queued in `broadcast_wait_ms` is an `error`, and it is counted as lost in `stats`. An HTTP handler may ignore it.

A connection that is too slow for its traffic is closed by the hub: it gets a `disconnect` frame with `reconnect: true`, and `unsubscribed` still runs.

## Stats

`Channels.stats(hub)` returns a `Channels.Stats`:

| Field | What it counts |
|---|---|
| `connections` | the connections now |
| `subscriptions` | the subscriptions now |
| `drops` | the connections that the hub closed for a full inbox |
| `lost` | the broadcasts that could not be queued |

## Disconnect a person

`Channels.disconnect(hub, identity, reconnect)` ends every connection whose `Identity.id` is `identity`. It is `remote_connections.where(...).disconnect` of Rails: each connection gets `{"type":"disconnect","reason":"remote","reconnect":RECONNECT}` and is closed with 1000, and `unsubscribed` runs for its subscriptions.

Use it when a person loses a right that `connect` or `subscribed` checked once: a sign-out, a deactivation, a removal from a room.

```agentica {mode="fragment"}
Channels.disconnect(hub, "ana", false).unwrap!
```

With `reconnect` false the client does not come back. With true it reconnects, and `connect` and `subscribed` decide again.

A broadcast queued after the call is not delivered to those connections. What a client sent before it, and is still queued, runs first. A connection that registers after the hub handled the call is not ended. An `error` means the hub did not take the request in `broadcast_wait_ms`, or is gone (and a gone hub has no connection left to end).

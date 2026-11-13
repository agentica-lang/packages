---
title: Channels
description: connect, the handlers of a channel, what subscribed decides, actions, and when a connection leaves.
weight: 1
---

## Who is connected

`MountOptions.connect` runs once for each connection, with the handshake of the WebSocket (so with its cookies). It returns the `Identity` of the person, or an `error`:

```agentica {mode="fragment"}
def connect(conn: Bond.Conn) -> Result[Channels.Identity]
  user = try Bond.cookie(conn, "user")
  return ok(Channels.Identity(id: user, data: JSON.from(user)))
end
```

`Identity.id` is the key of the person (for logs, presence and `Channels.disconnect`). `Identity.data` is JSON with whatever the handlers need, so the hub holds no type of your app.

An `error` is answered with `{"type":"disconnect","reason":"unauthorized","reconnect":false}` and the close code 1000. The client is not welcomed.

`connect` runs in the handler of the WebSocket, after the upgrade, and never in a `before` filter of Bond. A 302 or a 403 on the handshake makes the Rails client retry in a loop, so an app with a global sign-in filter exempts the cable path.

A handshake from another site is answered 403. `MountOptions.allowed_origins` lists the origins that are allowed, as in `Bond.websocket`. A client that does not offer the subprotocol `actioncable-v1-json` is closed with 1002.

## The handlers of a channel

`MountOptions.handlers` maps the channel names that the client sends (`"RoomChannel"`) to a `Channels.Handler`, which has three functions:

| Function | Type | When it runs |
|---|---|---|
| `subscribed` | `Fn[Session, JSON.Value, Result[Subscription]]` | the client subscribes; `params` is the whole identifier |
| `unsubscribed` | `Fn[Session, JSON.Value, Result[Void]]` | the client unsubscribes, or the connection ends in any way |
| `perform` | `Fn[Session, JSON.Value, String, JSON.Value, Result[List[JSON.Value]]]` | the client sends a message to the channel |

`Channels.handler(subscribed)` makes a handler that has no `unsubscribed` and takes no actions. Replace those with `with`:

```agentica {mode="fragment"}
room = Channels.handler(&subscribed).with(unsubscribed: on_leave, perform: on_action)
handlers = {"RoomChannel": room}
```

A `Session` has the number of the `connection`, its `identity`, and the `subscriptions` it holds now (their identifiers).

Every function runs on the task of its connection, the one that handles the commands of that client. A slow `perform` (a database call, a lock) stalls the next commands and pings of that client, and a connection whose `inbox` fills with them is dropped. Broadcasts do not queue there: the hub writes them to the WebSocket itself. Do the slow work in a task of your own and answer with a broadcast.

So a broadcast can reach the client before the reply of the `perform` that sent it; Action Cable does not promise that order either.

An `error` from any of them is logged, and the connection stays open. An `error` from `subscribed` also rejects the subscription.

## What subscribed decides

`subscribed` returns a `Subscription`:

| Field | Default | What it is |
|---|---|---|
| `streams` | `[]` | the topics whose broadcasts reach this subscription |
| `transmit` | `[]` | payloads for this connection only, sent before the confirmation; a JSON string is a Turbo Stream, an object is a notice |
| `rejected` | `false` | answer `reject_subscription` instead of the confirmation |

```agentica {mode="fragment"}
def subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  room = try room_of(params)
  greeting = JSON.from("welcome #{session.identity.id}")
  return ok(Channels.Subscription(streams: ["room:#{room}"], transmit: [greeting]))
end
```

A broadcast never reaches a client before the confirmation of its subscription. A connection holds at most 64 subscriptions; a subscribe over that is logged and ignored.

## Actions

A client message has an `action` and any other keys in its `data`. `perform` gets the `action` and the whole `data`, and returns the payloads to send to that connection only. A blank `action` is `receive`, as in Action Cable.

```agentica {mode="fragment"}
def acted(
  hub: Channels.Hub,
  session: Channels.Session,
  params: JSON.Value,
  action: String,
  data: JSON.Value,
) -> Result[List[JSON.Value]]
  room = try room_of(params)
  if action == "say"
    text = try JSON.string(try JSON.get(data, "text"))
    try Channels.broadcast_text(hub, "room:#{room}", "#{session.identity.id}: #{text}")
    return ok([])
  end

  return ok([JSON.from("unknown action #{action}")])
end
```

A client that sends `{"command":"message","identifier":"...","data":"{\"action\":\"say\",\"text\":\"yo\"}"}` makes every subscriber of the room hear `ana: yo`. Any other action gets `"unknown action NAME"` back, to that client only.

The block of a handler is not a function you can store in a map directly, so give its type a name first, with a function that returns its argument:

```agentica {mode="fragment"}
def leaving(f: Fn[Channels.Session, JSON.Value, Result[Void]]) -> Fn[Channels.Session, JSON.Value, Result[Void]]
  return f
end

on_leave = leaving do |session, params| left(hub, session, params) end
```

## What Action Cable only logs

As in Rails, these get no reply, and the connection stays open: a subscribe to a channel that is not in `handlers`, an unsubscribe of an identifier that is not subscribed, an action on a subscription that does not exist, and a frame that is not a command.

## When a connection ends

`unsubscribed` runs for each subscription when the client unsubscribes, closes, drops, is cut off for being too slow, or when its handler crashes. It is the place to announce that a person left:

```agentica {mode="fragment"}
def left(hub: Channels.Hub, session: Channels.Session, params: JSON.Value) -> Result[Void]
  room = try room_of(params)
  return Channels.broadcast_text(hub, "room:#{room}", "#{session.identity.id} left")
end
```

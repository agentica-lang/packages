---
title: bond-channels
description: Action Cable channels for Bond apps. One WebSocket per tab at /cable, channels and a pub/sub hub.
---

`bond-channels` adds an Action Cable WebSocket (the `actioncable-v1-json` protocol) to a [Bond](https://github.com/agentica-lang/bond) app. The browser opens one WebSocket per tab. It subscribes to channels, and the app sends to the subscribers of a topic with a broadcast, from an HTTP handler or from a channel.

It speaks the Rails protocol, so the Action Cable client of Rails and `<turbo-cable-stream-source>` of Turbo work with it. The stream names that Rails signs verify here, and the other way round.

## Install

Needs Agentica 0.27.0 or later and Bond 0.10.1. The app depends on Bond itself, at the same tag as the package, because two sources for one name in a tree is `PKG-SOURCE-CONFLICT`. Add both in a project with an `agentica.toml`:

```sh
agentica add bond https://github.com/agentica-lang/bond --tag 0.10.1
agentica add bond-channels https://github.com/agentica-lang/packages --tag bond-channels-0.2.1 --subdir bond-channels
```

That writes these lines of `agentica.toml`, and the entries of `agentica.lock`:

```toml
[dependencies]
bond = { git = "https://github.com/agentica-lang/bond", tag = "0.10.1" }
bond-channels = { git = "https://github.com/agentica-lang/packages", tag = "bond-channels-0.2.1", subdir = "bond-channels" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/bond-channels/CHANGELOG.md).

## Example

A chat room. A person is the cookie `user`. A subscription listens to the topic `room:ROOM`, and `GET /say?room=1&text=hi` tells everyone in room 1:

```agentica {mode="check"}
import Bond from "pkg/bond/bond"
import Channels from "pkg/bond-channels/channels"

# The person is the cookie "user"; a connection with no cookie is refused.
def connect(conn: Bond.Conn) -> Result[Channels.Identity]
  user = try Bond.cookie(conn, "user")
  return ok(Channels.Identity(id: user, data: JSON.from(user)))
end

def room_of(params: Json) -> Result[String]
  room = try JSON.get(params, "room")
  return JSON.string(room)
end

# A subscription listens to the topic of its room.
def subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  room = try room_of(params)
  return ok(Channels.Subscription(streams: ["room:#{room}"]))
end

# GET /say?room=1&text=hi tells every subscriber of the room.
def say(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  room = try Bond.query(conn, "room")
  text = try Bond.query(conn, "text")
  try Channels.broadcast_text(hub, "room:#{room}", text)
  return ok(Bond.text(conn, 200, "sent"))
end

def serving(handler: Fn[Bond.Conn, Result[Bond.Conn]]) -> Fn[Bond.Conn, Result[Bond.Conn]]
  return handler
end

def main() -> Void
  hub = Channels.start_hub().unwrap!
  say_it = serving() do |conn| say(hub, conn) end
  options = Channels.MountOptions(
    connect: &connect,
    handlers: {"RoomChannel": Channels.handler(&subscribed)},
  )

  app = Bond.app() |> Bond.get("/say", say_it)
  mounted = Channels.mount(app, "/cable", hub, options).unwrap!
  server = Bond.start_with(mounted, "127.0.0.1", 0, HttpServerOptions()).unwrap!
  puts("listening on #{Bond.local_port(server)}")
  IO.flush()
  Bond.wait(server).unwrap!
end
```

A client that connects to `/cable` with the subprotocol `actioncable-v1-json` and the cookie `user=ana` gets `{"type":"welcome"}`. After it sends `{"command":"subscribe","identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}"}`, it gets the confirmation, and then every `/say` of room 1:

```text
{"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","type":"confirm_subscription"}
{"identifier":"{\"channel\":\"RoomChannel\",\"room\":\"1\"}","message":"hi"}
```

The three parts:

- The **hub** (`Channels.start_hub`) is one task that holds the topics and sends the broadcasts.
- `Channels.mount` adds the WebSocket route to the Bond app. Its `connect` decides who the person is, and its `handlers` map the channel names of the client to their functions.
- A **broadcast** (`Channels.broadcast_text`, `Channels.broadcast_json`) sends to the subscribers of a topic. A subscription chooses its topics in `subscribed`.

## Pages

- [Channels](channels.md): `connect`, the handlers, what `subscribed` decides, actions, and when a connection leaves.
- [Turbo Streams](turbo.md): signed stream names and `<turbo-cable-stream-source>`.
- [The hub](hub.md): the options, the limits, `stats`, `disconnect` and `stop_hub`.

## API

Everything is under `Channels`, from `import Channels from "pkg/bond-channels/channels"`.

| Name | What it is |
|---|---|
| `Channels.start_hub(options)`, `Channels.stop_hub(hub)` | start and end the [hub](hub.md) |
| `Channels.mount(app, path, hub, options)` | adds the WebSocket route; returns a `Result[Bond.App]` |
| `Channels.handler(subscribed)`, `.with(...)` | a [channel handler](channels.md) |
| `Channels.broadcast_text(hub, topic, text)`, `Channels.broadcast_json(hub, topic, value)` | send to the subscribers of a topic |
| `Channels.stats(hub)` | the connections and subscriptions now, the drops and the lost broadcasts |
| `Channels.disconnect(hub, identity, reconnect)` | ends every connection of one person |
| `Channels.stream_key`, `signed_stream_name`, `verified_stream_name`, `turbo_streams` | [Turbo Streams](turbo.md) |
| `Channels.Hub`, `Identity`, `Session`, `Subscription`, `Handler`, `HubOptions`, `MountOptions`, `Stats` | the records |

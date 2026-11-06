## Action Cable for a Bond app: one WebSocket per tab at `/cable`, channels, and a pub/sub hub.
##
## ```ruby
## import Channels from "pkg/bond-channels/channels"
##
## hub = Channels.start_hub()
## app = Channels.mount(Bond.app(), "/cable", hub, &connect, {"RoomChannel": Channels.handler(&subscribed)})
## Channels.broadcast_text(hub, "room:1", "<turbo-stream>...</turbo-stream>")
## ```
##
## `connect` runs in the handler of the WebSocket, after the upgrade, never in a `before` filter: a 302 or a 403 on the
## handshake makes the Rails client retry in a loop, so an app with a global sign-in filter exempts the path. A
## WebSocket holds one of the `max_connections` of the Bond server for its whole life: set it above the clients and
## the posters.

import Bond from "pkg/bond/bond"
import HTTP from "std/http"
import Connection from "src/connection"
import Hubs from "src/hub"
import Protocol from "src/protocol"
import Types from "src/types"

export Types.Handler
export Types.Identity
export Types.Options
export Types.Session
export Types.Stats
export Types.Subscription
export Hubs.Hub

## Starts the hub: its task (which `main` awaits with `Task.await(hub.task)`) and the ticker. `options.broadcast_wait_ms`
## and `options.beat_ms` are the ones read here.
export def start_hub(options: Types.Options = Types.Options()) -> Hubs.Hub
  return Hubs.start(options)
end

## Ends the hub. Every broadcast after it fails with "closed".
export def stop_hub(hub: Hubs.Hub) -> Result[Void]
  return Hubs.stop(hub)
end

## A handler of a channel that has no `unsubscribed` and takes no actions; replace those with `handler.with(...)`.
export def handler(subscribed: Fn[Types.Session, Json, Result[Types.Subscription]]) -> Types.Handler
  return Types.Handler(subscribed: subscribed, unsubscribed: &nothing_to_leave, perform: &no_actions)
end

## Sends `text` (Turbo Stream HTML) to the subscribers of `topic`, as a JSON string. A broadcast that cannot be queued
## in `broadcast_wait_ms` is an `error`, and counted as lost in `stats`; an HTTP handler may ignore it.
export def broadcast_text(hub: Hubs.Hub, topic: String, text: String) -> Result[Void]
  return Hubs.broadcast(hub, topic, Protocol.text_payload(text))
end

## Sends `value` to the subscribers of `topic`, as a JSON value (an object for a notice).
export def broadcast_json(hub: Hubs.Hub, topic: String, value: Json) -> Result[Void]
  return Hubs.broadcast(hub, topic, Protocol.json_payload(value))
end

## The connections and subscriptions now, the connections dropped for a full inbox, and the broadcasts lost.
export def stats(hub: Hubs.Hub) -> Types.Stats
  return Hubs.stats(hub)
end

## Adds the cable WebSocket at `path` (`"/cable"` for the clients that expect it). `connect` gives the identity of the
## person from the handshake (its cookies), or an `error` that is answered with an `unauthorized` disconnect.
## `handlers` maps the channel names of the client to their functions. An origin is checked as in `Bond.websocket`.
export def mount(
  app: Bond.App,
  path: String,
  hub: Hubs.Hub,
  connect: Fn[Bond.Conn, Result[Types.Identity]],
  handlers: Map[String, Types.Handler],
  allowed_origins: List[String] = [],
  options: Types.Options = Types.Options(),
) -> Bond.App
  context = Connection.Mount(hub: hub, connect: connect, handlers: handlers, options: options)
  serving = Connection.handler_of(context)
  websocket = HTTP.WebSocketOptions(
    max_message_bytes: options.max_message_bytes,
    idle_ms: options.idle_ms,
    protocols: [Protocol.SUBPROTOCOL],
  )

  return Bond.websocket(app, path, serving, allowed_origins, some(websocket))
end

def nothing_to_leave(session: Types.Session, params: Json) -> Result[Void]
  return ok()
end

def no_actions(session: Types.Session, params: Json, action: String, data: Json) -> Result[List[Json]]
  payloads: List[Json] = []
  return ok(payloads)
end

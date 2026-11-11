## Action Cable for a Bond app: one WebSocket per tab at `/cable`, channels, and a pub/sub hub.
##
## ```ruby
## import Bond from "pkg/bond/bond"
## import Channels from "pkg/bond-channels/channels"
##
## hub = Channels.start_hub().unwrap!
## options = Channels.MountOptions(connect: &connect, handlers: {"RoomChannel": Channels.handler(&subscribed)})
## app = Channels.mount(Bond.app(), "/cable", hub, options).unwrap!
## Channels.broadcast_text(hub, "room:1", "<turbo-stream>...</turbo-stream>")
## ```
##
## `connect` runs in the handler of the WebSocket, after the upgrade, never in a `before` filter: a 302 or a 403 on the
## handshake makes the Rails client retry in a loop, so an app with a global sign-in filter exempts the path. A
## WebSocket holds one of the `max_connections` of the Bond server for its whole life: set it above the clients and
## the posters.
##
## When the hub ends (`stop_hub`) or crashes, its connections are told to reconnect and are closed, and a new one is
## refused the same way.

import Bond from "pkg/bond/bond"
import HTTP from "std/http"
import Connection from "src/connection"
import Hubs from "src/hub"
import Protocol from "src/protocol"
import Signing from "src/signing"
import Turbo from "src/turbo"
import Types from "src/types"

export Types.Handler
export Types.Identity
export Types.HubOptions
export Types.MountOptions
export Types.Session
export Types.Stats
export Types.Subscription
export Hubs.Hub

## Starts the hub: its task (which `main` awaits with `Task.await(hub.task)`) and the ticker. An `error` for a
## `beat_ms` under 1 or a negative `broadcast_wait_ms`.
export def start_hub(options: Types.HubOptions = Types.HubOptions()) -> Result[Hubs.Hub] = Hubs.start(options)

## Ends the hub. Every broadcast after it fails with "closed", and its connections are told to reconnect and closed.
export def stop_hub(hub: Hubs.Hub) -> Result[Void] = Hubs.stop(hub)

## Ends every connection of the person whose `Identity.id` is `identity`, as `remote_connections.where(...).disconnect`
## of Rails does: each gets `{"type":"disconnect","reason":"remote","reconnect":RECONNECT}` and is closed, running
## `unsubscribed` for its subscriptions. Use it when a person loses a right that `connect` or `subscribed` checked once:
## a sign-out, a deactivation, a removal from a room. With `reconnect` false the client does not come back; with true
## it reconnects, and `connect` and `subscribed` decide again. A broadcast queued after the call is not delivered to
## those connections, and what a client sent before it and is still queued runs first. A connection that registers
## after the hub handled the call is not ended (one that registered before is, as the hub works in order). An `error` is
## a hub that did not take the request in `broadcast_wait_ms` or is gone (a gone hub has no connection left to end).
export def disconnect(hub: Hubs.Hub, identity: String, reconnect: Bool) -> Result[Void]
  Hubs.remove(hub, identity, reconnect)
end

## A handler of a channel that has no `unsubscribed` and takes no actions; replace those with `handler.with(...)`.
export def handler(subscribed: Fn[Types.Session, Json, Result[Types.Subscription]]) -> Types.Handler
  Types.Handler(subscribed: subscribed, unsubscribed: &nothing_to_leave, perform: &no_actions)
end

## The key that signs and verifies the stream names of the pages (`signed_stream_name`), from the secret of the app (a
## Rails secret too: a name that Rails signed with it verifies). Make it once at start-up; an empty secret is an
## `error`.
export def stream_key(secret_key_base: String) -> Result[Bytes] = Signing.stream_key(secret_key_base)

## The stream name that a page puts in `<turbo-cable-stream-source channel="..." signed-stream-name="...">`. `name` is
## the parts of the stream joined with `:`, as `Turbo::StreamsChannel.broadcast_*_to` joins them.
export def signed_stream_name(key: Bytes, name: String) -> String = Signing.signed_stream_name(key, name)

## The name in `signed` if `key` signed it, `none` for anything else (a bad signature or a message that is not a name).
export def verified_stream_name(key: Bytes, signed: String) -> Optional[String]
  Signing.verified_stream_name(key, signed)
end

## A handler for `<turbo-cable-stream-source>`: it verifies the `signed_stream_name` of the client and streams from the
## name in it, or rejects the subscription when it does not verify or `authorize(session, name)` is false. Register it
## under the channel names that the page uses (`Turbo::StreamsChannel`, or one of your own).
export def turbo_streams(key: Bytes, authorize: Fn[Types.Session, String, Bool]) -> Types.Handler
  handler(Turbo.subscribing(key, authorize))
end

## Sends `text` (Turbo Stream HTML) to the subscribers of `topic`, as a JSON string. A broadcast that cannot be queued
## in `broadcast_wait_ms` is an `error`, and counted as lost in `stats`; an HTTP handler may ignore it.
export def broadcast_text(hub: Hubs.Hub, topic: String, text: String) -> Result[Void]
  Hubs.broadcast(hub, topic, Protocol.text_payload(text))
end

## Sends `value` to the subscribers of `topic`, as a JSON value (an object for a notice).
export def broadcast_json(hub: Hubs.Hub, topic: String, value: Json) -> Result[Void]
  Hubs.broadcast(hub, topic, Protocol.json_payload(value))
end

## The connections and subscriptions now, the connections dropped for a full inbox, and the broadcasts lost.
export def stats(hub: Hubs.Hub) -> Types.Stats = Hubs.stats(hub)

## Adds the cable WebSocket at `path` (`"/cable"` for the clients that expect it); `options.connect` and
## `options.handlers` are described at `MountOptions`. An origin is checked as in `Bond.websocket`. An `error` for
## options that cannot work: an `inbox` under 1, a negative `idle_ms` or `max_message_bytes` under 1, or an `idle_ms`
## that is not more than the `beat_ms` of the hub (the WebSocket ping that keeps a quiet client could never come in
## time).
export def mount(app: Bond.App, path: String, hub: Hubs.Hub, options: Types.MountOptions) -> Result[Bond.App]
  try checked(hub, options)
  context = Connection.Mount(hub: hub, options: options)
  serving = Connection.handler_of(context)
  websocket = HTTP.WebSocketOptions(
    max_message_bytes: options.max_message_bytes,
    idle_ms: options.idle_ms,
    protocols: [Protocol.SUBPROTOCOL],
  )

  ok(Bond.websocket(app, path, serving, options.allowed_origins, some(websocket)))
end

def checked(hub: Hubs.Hub, options: Types.MountOptions) -> Result[Void]
  return error("inbox must be 1 or more, it is #{options.inbox}") if options.inbox < 1

  if options.max_message_bytes < 1
    return error("max_message_bytes must be 1 or more, it is #{options.max_message_bytes}")
  end

  return error("idle_ms must be 0 (no limit) or more, it is #{options.idle_ms}") if options.idle_ms < 0

  if options.idle_ms > 0 and options.idle_ms <= hub.options.beat_ms
    return error("idle_ms (#{options.idle_ms}) must be more than the beat_ms of the hub (#{hub.options.beat_ms})")
  end

  ok()
end

def nothing_to_leave(session: Types.Session, params: Json) -> Result[Void] = ok()

def no_actions(session: Types.Session, params: Json, action: String, data: Json) -> Result[List[Json]]
  payloads: List[Json] = []
  ok(payloads)
end

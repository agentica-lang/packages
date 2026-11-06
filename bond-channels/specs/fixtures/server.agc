## The program of `cable.feature`: a Bond app with the cable at `/cable` on 127.0.0.1 and a free port, which it says on
## its first line. The settings come from the environment (`BEAT_MS`, `IDLE_MS`, `INBOX`, `MAX_MESSAGE_BYTES`,
## `MAX_CONNECTIONS`).
##
## `connect` takes the person from the cookie `user`. `RoomChannel` streams `room:ROOM` (its `room` param), and the
## actions of its clients are `say` (a broadcast to the room), `slow` (a handler that announces itself on `left`, then
## takes 1.5 s), `crash` (a runtime error) and any other (answered to that connection only). Whoever leaves a room, in
## any way, is announced as an object on the topic `left`, which `WatchChannel` streams. `GreetChannel` transmits a
## greeting when it is subscribed, `RefusedChannel` is rejected and `FailingChannel` answers `subscribed` with an
## `error`. `GET /say?topic=T&text=X` broadcasts a Turbo Stream from an HTTP handler, `GET /stats` answers
## `Channels.stats` and `GET /stop` stops the hub.

import Bond from "pkg/bond/bond"
import Channels from "../../channels"

DEFAULT_BEAT_MS = 3_000
DEFAULT_IDLE_MS = 120_000
SLOW_MS = 1_500
DEFAULT_MAX_CONNECTIONS = 256

struct Notice
  left: String
  room: String
end

struct Started
  started: String
end

struct Counts
  connections: Int
  subscriptions: Int
  drops: Int
  lost: Int
end

def setting(name: String, fallback: Int) -> Int
  case System.env(name)
    ok(text) -> return text.to_i.unwrap_or(fallback)
    error(_) -> return fallback
  end
end

def connect(conn: Bond.Conn) -> Result[Channels.Identity]
  user = try Bond.cookie(conn, "user")
  return ok(Channels.Identity(id: user, data: JSON.from(user)))
end

def text_field(data: Json, name: String) -> Result[String]
  field = try JSON.get(data, name)
  return JSON.string(field)
end

def room_of(params: Json) -> String
  return text_field(params, "room").unwrap_or("lobby")
end

def room_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return ok(Channels.Subscription(streams: ["room:#{room_of(params)}"]))
end

def room_left(hub: Channels.Hub, session: Channels.Session, params: Json) -> Result[Void]
  notice = JSON.from(Notice(left: session.identity.id, room: room_of(params)))
  return Channels.broadcast_json(hub, "left", notice)
end

def room_acted(
  hub: Channels.Hub,
  session: Channels.Session,
  params: Json,
  action: String,
  data: Json,
) -> Result[List[Json]]
  case action
    "say" ->
      text = try text_field(data, "text")
      try Channels.broadcast_text(hub, "room:#{room_of(params)}", "#{session.identity.id}: #{text}")
      return ok([])
    "slow" ->
      # The announcement tells a step that this handler is running, so that it needs no fixed wait.
      try Channels.broadcast_json(hub, "left", JSON.from(Started(started: session.identity.id)))
      Task.sleep(SLOW_MS)
      return ok([])
    "crash" -> return ok([JSON.from(1 / (action.length - 5))])
    _ -> return ok([JSON.from({"action": JSON.from(action)})])
  end
end

def watch_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return ok(Channels.Subscription(streams: ["left"]))
end

def greet_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return ok(Channels.Subscription(transmit: [JSON.from("hello #{session.identity.id}")]))
end

def failing_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return error("the channel is broken")
end

def refused_subscribed(session: Channels.Session, params: Json) -> Result[Channels.Subscription]
  return ok(Channels.Subscription(rejected: true))
end

# A block follows a call, so these give the blocks of `handlers` a typed name first.
def leaving(f: Fn[Channels.Session, Json, Result[Void]]) -> Fn[Channels.Session, Json, Result[Void]]
  return f
end

def acting(
  f: Fn[Channels.Session, Json, String, Json, Result[List[Json]]],
) -> Fn[Channels.Session, Json, String, Json, Result[List[Json]]]
  return f
end

def handlers(hub: Channels.Hub) -> Map[String, Channels.Handler]
  left = leaving() do |session, params| room_left(hub, session, params) end
  acted = acting() do |session, params, action, data| room_acted(hub, session, params, action, data) end
  return {
    "RoomChannel": Channels.handler(&room_subscribed).with(unsubscribed: left, perform: acted),
    "WatchChannel": Channels.handler(&watch_subscribed),
    "GreetChannel": Channels.handler(&greet_subscribed),
    "RefusedChannel": Channels.handler(&refused_subscribed),
    "FailingChannel": Channels.handler(&failing_subscribed),
  }
end

def say(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  topic = try Bond.query(conn, "topic")
  text = try Bond.query(conn, "text")
  try Channels.broadcast_text(hub, topic, text)
  return ok(Bond.text(conn, 200, "sent"))
end

def counts(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  stats = Channels.stats(hub)
  body = Counts(
    connections: stats.connections,
    subscriptions: stats.subscriptions,
    drops: stats.drops,
    lost: stats.lost,
  )

  return ok(Bond.json(conn, 200, JSON.from(body)))
end

def stop(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  try Channels.stop_hub(hub)
  return ok(Bond.text(conn, 200, "stopped"))
end

def serving(handler: Fn[Bond.Conn, Result[Bond.Conn]]) -> Fn[Bond.Conn, Result[Bond.Conn]]
  return handler
end

def main() -> Void
  hub = Channels.start_hub(Channels.HubOptions(beat_ms: setting("BEAT_MS", DEFAULT_BEAT_MS))).unwrap!
  say_it = serving() do |conn| say(hub, conn) end
  count_it = serving() do |conn| counts(hub, conn) end
  stop_it = serving() do |conn| stop(hub, conn) end
  app = (
    Bond.app()
    |> Bond.get("/say", say_it)
    |> Bond.get("/stats", count_it)
    |> Bond.get("/stop", stop_it)
  )

  options = Channels.MountOptions(
    connect: &connect,
    handlers: handlers(hub),
    inbox: setting("INBOX", 256),
    idle_ms: setting("IDLE_MS", DEFAULT_IDLE_MS),
    max_message_bytes: setting("MAX_MESSAGE_BYTES", 65_536),
  )

  mounted = Channels.mount(app, "/cable", hub, options).unwrap!
  server = Bond.start_with(
    mounted,
    "127.0.0.1",
    0,
    HttpServerOptions(max_connections: setting("MAX_CONNECTIONS", DEFAULT_MAX_CONNECTIONS)),
  ).unwrap!

  puts("listening on #{Bond.local_port(server)}")
  IO.flush()
  Bond.wait(server).unwrap!
end

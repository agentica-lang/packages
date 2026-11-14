## The program of `cable.feature`: a Bond app with the cable at `/cable` on 127.0.0.1 and a free port, which it says on
## its first line. The settings come from the environment (`BEAT_MS`, `IDLE_MS`, `INBOX`, `MAX_MESSAGE_BYTES`,
## `MAX_CONNECTIONS`, `SLOW_MS`: how long the `slow` action holds its connection).
##
## `connect` takes the person from the cookie `user`. `RoomChannel` streams `room:ROOM` (its `room` param), and the
## actions of its clients are `say` (a broadcast to the room), `slow` (a handler that announces itself on `left`, then
## takes 1.5 s), `crash` (a runtime error) and any other (answered to that connection only). Whoever leaves a room, in
## any way, is announced as an object on the topic `left`, which `WatchChannel` streams. `GreetChannel` transmits a
## greeting when it is subscribed, `RefusedChannel` is rejected and `FailingChannel` answers `subscribed` with an
## `error`. `GET /say?topic=T&text=X` broadcasts a Turbo Stream from an HTTP handler, `GET /stats` answers
## `Channels.stats`, `GET /disconnect?user=U&reconnect=BOOL` is `Channels.disconnect`, `GET /stop` stops the hub and `GET /signed?name=N` answers the signed stream name of N.
## `Turbo::StreamsChannel` is `Channels.turbo_streams` with a key of this program, and refuses the names that start
## with `secret:`.

import HTTP from "std/http"
import Bond from "pkg/bond/bond"
import Channels from "../../channels"

private

DEFAULT_BEAT_MS = 3_000
DEFAULT_IDLE_MS = 120_000
DEFAULT_SLOW_MS = 1_500
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
    ok(text) -> text.to_i.unwrap_or(fallback)
    error(_) -> fallback
  end
end

def connect(conn: Bond.Conn) -> Result[Channels.Identity]
  user = try Bond.cookie(conn, "user")
  ok(Channels.Identity(id: user, data: JSON.from(user)))
end

def text_field(data: JSON.Value, name: String) -> Result[String]
  field = try JSON.get(data, name)
  JSON.string(field)
end

def room_of(params: JSON.Value) -> String = text_field(params, "room").unwrap_or("lobby")

def room_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  ok(Channels.Subscription(streams: ["room:#{room_of(params)}"]))
end

def room_left(hub: Channels.Hub, session: Channels.Session, params: JSON.Value) -> Result[Void]
  notice = JSON.from(Notice(left: session.identity.id, room: room_of(params)))
  Channels.broadcast_json(hub, "left", notice)
end

def room_acted(
  hub: Channels.Hub,
  session: Channels.Session,
  params: JSON.Value,
  action: String,
  data: JSON.Value,
) -> Result[List[JSON.Value]]
  case action
    "say" ->
      text = try text_field(data, "text")
      try Channels.broadcast_text(hub, "room:#{room_of(params)}", "#{session.identity.id}: #{text}")
      ok([])
    "slow" ->
      # The announcement tells a step that this handler is running, so that it needs no fixed wait.
      try Channels.broadcast_json(hub, "left", JSON.from(Started(started: session.identity.id)))
      Task.sleep(setting("SLOW_MS", DEFAULT_SLOW_MS))
      ok([])
    "crash" -> ok([JSON.from(1 / (action.length - 5))])
    _ -> ok([JSON.from({"action": JSON.from(action)})])
  end
end

def watch_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  ok(Channels.Subscription(streams: ["left"]))
end

def greet_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  ok(Channels.Subscription(transmit: [JSON.from("hello #{session.identity.id}")]))
end

def failing_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  error("the channel is broken")
end

def refused_subscribed(session: Channels.Session, params: JSON.Value) -> Result[Channels.Subscription]
  ok(Channels.Subscription(rejected: true))
end

def readable?(session: Channels.Session, name: String) -> Bool = not name.start_with?("secret:")

def handlers(hub: Channels.Hub, key: Bytes) -> Map[String, Channels.Handler]
  left = ->(session, params) { room_left(hub, session, params) }
  acted = ->(session, params, action, data) { room_acted(hub, session, params, action, data) }
  {
    "RoomChannel": Channels.handler(&room_subscribed).with(unsubscribed: left, perform: acted),
    "WatchChannel": Channels.handler(&watch_subscribed),
    "GreetChannel": Channels.handler(&greet_subscribed),
    "RefusedChannel": Channels.handler(&refused_subscribed),
    "FailingChannel": Channels.handler(&failing_subscribed),
    "Turbo::StreamsChannel": Channels.turbo_streams(key, &readable?),
  }
end

def say(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  topic = try Bond.query(conn, "topic")
  text = try Bond.query(conn, "text")
  try Channels.broadcast_text(hub, topic, text)
  ok(Bond.text(conn, 200, "sent"))
end

def counts(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  stats = Channels.stats(hub)
  body = Counts(
    connections: stats.connections,
    subscriptions: stats.subscriptions,
    drops: stats.drops,
    lost: stats.lost,
  )

  ok(Bond.json(conn, 200, JSON.from(body)))
end

def signed(key: Bytes, conn: Bond.Conn) -> Result[Bond.Conn]
  name = try Bond.query(conn, "name")
  ok(Bond.text(conn, 200, Channels.signed_stream_name(key, name)))
end

def disconnect(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  user = try Bond.query(conn, "user")
  again = try Bond.query(conn, "reconnect")
  try Channels.disconnect(hub, user, again == "true")
  ok(Bond.text(conn, 200, "disconnected"))
end

def stop(hub: Channels.Hub, conn: Bond.Conn) -> Result[Bond.Conn]
  try Channels.stop_hub(hub)
  ok(Bond.text(conn, 200, "stopped"))
end

def main() -> Void
  hub = Channels.start_hub(Channels.HubOptions(beat_ms: setting("BEAT_MS", DEFAULT_BEAT_MS))).unwrap!
  key = Channels.stream_key("the secret of the specs").unwrap!
  app = (
    Bond.app()
    |> Bond.get("/say", ->(conn) { say(hub, conn) })
    |> Bond.get("/stats", ->(conn) { counts(hub, conn) })
    |> Bond.get("/stop", ->(conn) { stop(hub, conn) })
    |> Bond.get("/disconnect", ->(conn) { disconnect(hub, conn) })
    |> Bond.get("/signed", ->(conn) { signed(key, conn) })
  )

  options = Channels.MountOptions(
    connect: &connect,
    handlers: handlers(hub, key),
    inbox: setting("INBOX", 256),
    idle_ms: setting("IDLE_MS", DEFAULT_IDLE_MS),
    max_message_bytes: setting("MAX_MESSAGE_BYTES", 65_536),
  )

  mounted = Channels.mount(app, "/cable", hub, options).unwrap!
  server = Bond.start_with(
    mounted,
    "127.0.0.1",
    0,
    HTTP.ServerOptions(max_connections: setting("MAX_CONNECTIONS", DEFAULT_MAX_CONNECTIONS)),
  ).unwrap!

  puts("listening on #{Bond.local_port(server)}")
  IO.flush()
  Bond.wait(server).unwrap!
end

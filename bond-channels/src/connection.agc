## One cable connection, in the handler of a Bond WebSocket route. The handler task owns the state that must outlive
## a crash (which subscriptions the connection holds); a task of its own runs the commands and writes the frames, so
## a handler that crashes ends that task, not this one, and `unsubscribed` still runs for every subscription.

import Bond from "pkg/bond/bond"
import HTTP from "std/http"
import Hub from "hub"
import Protocol from "protocol"
import Types from "types"

MAX_SUBSCRIPTIONS = 64
# A client that does not read for this long is cut off (the outgoing channel of std/http holds only 8 messages).
WRITE_MS = 5_000
PUMP_MS = 60_000
# How often an idle loop looks at the hub: a hub that ended or crashed sends nothing more, so this is how its
# connections find out.
HUB_CHECK_MS = 2_000
MAX_WEBSOCKET_PING_MS = 30_000
# 1002: a protocol error, what a client that offers no `actioncable-v1-json` gets.
NO_SUBPROTOCOL = 1_002
# 1000: a normal close, what a connection that `Channels.disconnect` ended gets.
NORMAL_CLOSE = 1_000
# 1001: going away, what a client gets when the hub is gone.
GOING_AWAY = 1_001
TRY_LATER = 1_013

## What `mount` gives to every connection.
export struct Mount
  hub: Hub.Hub
  options: Types.MountOptions
end

# The task of the loop: everything it needs, besides its inbox, which it owns.
struct Line
  mount: Mount
  socket: HTTP.WebSocket
  connection: Int
  identity: Types.Identity
  subscriptions: ATS[String, String]
end

## The handler of the Bond route.
export def handler_of(mount: Mount) -> Bond.WebSocketHandler
  return wrapping() do |conn, socket| serve(mount, conn, socket) end
end

# Serves one WebSocket until it ends, then runs `unsubscribed` for every subscription it still holds.
def serve(mount: Mount, conn: Bond.Conn, socket: HTTP.WebSocket) -> Result[Void]
  # std/http picks the first protocol of the client that is in `protocols`; none means the client wants another one.
  if socket.protocol != Protocol.SUBPROTOCOL
    return write_close(socket, NO_SUBPROTOCOL, "#{Protocol.SUBPROTOCOL} is required")
  end

  case mount.options.connect.call(conn)
    ok(identity) -> return open(mount, socket, identity)
    error(reason) ->
      IO.warn("bond-channels: connection refused: #{reason}")
      return socket.outgoing.send(HTTP.Message.Text(Protocol.disconnect_unauthorized()), WRITE_MS)
  end
end

def wrapping(handler: Bond.WebSocketHandler) -> Bond.WebSocketHandler
  return handler
end

def write_close(socket: HTTP.WebSocket, code: Int, reason: String) -> Result[Void]
  return socket.outgoing.send(HTTP.Message.Close(code, reason), WRITE_MS)
end

# A hub that is gone (stopped or crashed) hears nothing: the client is told to reconnect and is closed, as when a
# server restarts, instead of being welcomed into a connection that no broadcast could reach.
def hub_gone(socket: HTTP.WebSocket) -> Result[Void]
  return send_away(socket, GOING_AWAY, "the hub is gone")
end

# 1013: try again later. The hub is there but its inbox stayed full for `broadcast_wait_ms`: the client reconnects too.
def hub_busy(socket: HTTP.WebSocket) -> Result[Void]
  IO.warn("bond-channels: the hub inbox is full, a connection was refused")
  return send_away(socket, TRY_LATER, "the hub is busy")
end

def send_away(socket: HTTP.WebSocket, code: Int, reason: String) -> Result[Void]
  try socket.outgoing.send(HTTP.Message.Text(Protocol.disconnect_reconnect()), WRITE_MS)
  return write_close(socket, code, reason)
end

def open(mount: Mount, socket: HTTP.WebSocket, identity: Types.Identity) -> Result[Void]
  hub = mount.hub
  if Hub.gone?(hub)
    return hub_gone(socket)
  end

  connection = Hub.next_connection(hub)
  subscriptions: ATS[String, String] = ATS.new()
  line = Line(mount: mount, socket: socket, connection: connection, identity: identity, subscriptions: subscriptions)
  inbox: Channel[Hub.Event] = Channel.new(mount.options.inbox)
  # Before any command is handled: the browser waits for it, and the loadgen subscribes right after the handshake.
  try socket.outgoing.send(HTTP.Message.Text(Protocol.welcome()), WRITE_MS)
  if not Hub.register(hub, connection, identity.id, inbox, ping_every(mount.options, hub)).ok?
    if Hub.gone?(hub)
      return hub_gone(socket)
    end

    return hub_busy(socket)
  end

  Hub.count(hub, Hub.CONNECTIONS, 1)
  pump = Task.spawn() do pump(socket, inbox) end
  # The loop owns the inbox: it closes when the loop ends or crashes, so the hub sees "closed" and the pump stops.
  body = looping() do |owned| loop(line, owned) end
  outcome = Task.await(Task.spawn_owning(body, inbox))
  Task.cancel(pump)
  if not outcome.ok?
    IO.warn("bond-channels: connection #{connection} ended with an error: #{outcome.message}")
  end

  finish(line)
  Hub.count(hub, Hub.CONNECTIONS, -1)
  # It forgets every subscription of the connection at once. A hub that is gone has nothing left to forget.
  _ = Hub.disconnect(hub, connection)
  return ok()
end

# A block cannot be assigned to a name: this gives it a typed parameter first, so that it is a function that takes
# the inbox, which `Task.spawn_owning` hands over.
def looping(body: Fn[Channel[Hub.Event], Result[Void]]) -> Fn[Channel[Hub.Event], Result[Void]]
  return body
end

# The hub also pings the WebSocket, so that the pong of a quiet peer resets the idle clock of std/http: the Action
# Cable ping is always something to write, so std/http would never ping by itself.
def ping_every(options: Types.MountOptions, hub: Hub.Hub) -> Int
  interval = MAX_WEBSOCKET_PING_MS
  if options.idle_ms > 0 and options.idle_ms / 3 < interval
    interval = options.idle_ms / 3
  end

  # `start_hub` refuses a `beat_ms` under 1.
  every = interval / hub.options.beat_ms
  if every < 1
    return 1
  end

  return every
end

# There is no `select`: this moves the messages of the client into the inbox, next to the frames of the hub. It ends
# when the inbox is closed (the loop is over) or the client is, never because the loop was slow for a moment.
def pump(socket: HTTP.WebSocket, inbox: Channel[Hub.Event]) -> Result[Void]
  while true
    case socket.incoming.recv(PUMP_MS)
      ok(message) ->
        if not deliver(inbox, Hub.Event.Client(message)) or closing?(message)
          return ok()
        end

      error(_) ->
        if socket.incoming.closed? and socket.incoming.empty?
          _ = inbox.send(Hub.Event.Client(HTTP.Message.Close(1_006, "")), 0)
          return ok()
        end
    end
  end

  return ok()
end

# A loop that is busy (a slow handler) holds the pump here, and so the client: the backlog stays in the socket, not
# in memory. False when the inbox is closed.
def deliver(inbox: Channel[Hub.Event], event: Hub.Event) -> Bool
  while true
    if inbox.send(event, WRITE_MS).ok?
      return true
    end

    if inbox.closed?
      return false
    end
  end

  return false
end

def closing?(message: HTTP.Message) -> Bool
  case message
    HTTP.Message.Close(_, _) -> return true
    HTTP.Message.Text(_) -> return false
    HTTP.Message.Binary(_) -> return false
    HTTP.Message.Ping(_) -> return false
    HTTP.Message.Pong(_) -> return false
  end
end

def loop(line: Line, inbox: Channel[Hub.Event]) -> Result[Void]
  while true
    case inbox.recv(HUB_CHECK_MS)
      ok(event) ->
        if not try handle(line, event)
          return ok()
        end

      error(_) ->
        # The hub closes an inbox that is full; what was queued has been written by now. The browser reconnects.
        if inbox.closed? and inbox.empty?
          return write(line, HTTP.Message.Text(Protocol.disconnect_reconnect()))
        end

        if Hub.gone?(line.mount.hub)
          return hub_gone(line.socket)
        end
    end
  end

  return ok()
end

# False when the connection is over.
def handle(line: Line, event: Hub.Event) -> Result[Bool]
  case event
    Hub.Event.Frame(text) ->
      try write(line, HTTP.Message.Text(text))
      return ok(true)
    Hub.Event.Ping ->
      try write(line, HTTP.Message.Ping("".bytes))
      return ok(true)
    Hub.Event.Client(message) -> return client(line, message)
    Hub.Event.Away(reconnect) -> return away(line, reconnect)
  end
end

# `Channels.disconnect`: the frame that says whether to come back, then the close; the loop ends.
def away(line: Line, reconnect: Bool) -> Result[Bool]
  try write(line, HTTP.Message.Text(Protocol.disconnect_remote(reconnect)))
  try write(line, HTTP.Message.Close(NORMAL_CLOSE, "disconnected"))
  return ok(false)
end

def client(line: Line, message: HTTP.Message) -> Result[Bool]
  case message
    HTTP.Message.Text(text) ->
      try command(line, text)
      return ok(true)
    HTTP.Message.Close(_, _) -> return ok(false)
    HTTP.Message.Binary(_) -> return ok(true)
    HTTP.Message.Ping(_) -> return ok(true)
    HTTP.Message.Pong(_) -> return ok(true)
  end
end

def write(line: Line, message: HTTP.Message) -> Result[Void]
  return line.socket.outgoing.send(message, WRITE_MS)
end

def transmit(line: Line, identifier: String, payloads: List[Json]) -> Result[Void]
  for payload in payloads
    try write(line, HTTP.Message.Text(Protocol.message(identifier, Protocol.json_payload(payload))))
  end

  return ok()
end

# What Action Cable only logs (a bad frame, an unknown channel or subscription) is logged and the connection stays.
def command(line: Line, text: String) -> Result[Void]
  case Protocol.decode_command(text)
    error(reason) ->
      IO.warn("bond-channels: ignored a frame: #{reason}")
      return ok()
    ok(decoded) ->
      case decoded
        Protocol.Command.Subscribe(join) -> return subscribe(line, join)
        Protocol.Command.Unsubscribe(identifier) -> return unsubscribe(line, identifier)
        Protocol.Command.Perform(action) -> return perform(line, action)
      end
  end
end

def session(line: Line) -> Types.Session
  return Types.Session(connection: line.connection, identity: line.identity, subscriptions: line.subscriptions.keys)
end

def subscribe(line: Line, join: Protocol.Join) -> Result[Void]
  if line.subscriptions.has_key?(join.identifier)
    return ok()
  end

  if line.subscriptions.size >= MAX_SUBSCRIPTIONS
    IO.warn("bond-channels: more than #{MAX_SUBSCRIPTIONS} subscriptions on connection #{line.connection}")
    return ok()
  end

  case line.mount.options.handlers.get(join.channel)
    none ->
      IO.warn("bond-channels: no channel #{join.channel}")
      return ok()
    some(handler) -> return subscribe_to(line, handler, join)
  end
end

def subscribe_to(line: Line, handler: Types.Handler, join: Protocol.Join) -> Result[Void]
  # Recorded before `subscribed` runs, as Rails does: if it crashes, `unsubscribed` still runs at the end.
  line.subscriptions.put(join.identifier, join.channel)
  Hub.count(line.mount.hub, Hub.SUBSCRIPTIONS, 1)
  case handler.subscribed.call(session(line), join.params)
    error(reason) ->
      IO.warn("bond-channels: subscribing to #{join.channel} failed: #{reason}")
      return refuse(line, handler, join)
    ok(decision) -> return decide(line, handler, join, decision)
  end
end

def decide(line: Line, handler: Types.Handler, join: Protocol.Join, decision: Types.Subscription) -> Result[Void]
  try transmit(line, join.identifier, decision.transmit)
  if decision.rejected or not attached?(line, join.identifier, decision.streams)
    return refuse(line, handler, join)
  end

  return write(line, HTTP.Message.Text(Protocol.confirm_subscription(join.identifier)))
end

# The client is told, and the subscription is forgotten: the hub never heard of it (an attach that failed was not
# queued), so only the table and `unsubscribed` need it.
def refuse(line: Line, handler: Types.Handler, join: Protocol.Join) -> Result[Void]
  try forget(line, handler, join.identifier, join.params)
  return write(line, HTTP.Message.Text(Protocol.reject_subscription(join.identifier)))
end

# The hub queue is FIFO, so a broadcast sent after this one reaches the inbox after the confirmation is written. A
# hub that does not take the message rejects the subscription: it could never hear a broadcast.
def attached?(line: Line, identifier: String, streams: List[String]) -> Bool
  if streams.empty?
    return true
  end

  return Hub.attach(line.mount.hub, line.connection, identifier, streams).ok?
end

# A subscription that ends: out of the table, and `unsubscribed` runs. The hub is not told here: `leave` does it for a
# client that unsubscribes, and `Disconnect` does it for the whole connection.
def forget(line: Line, handler: Types.Handler, identifier: String, params: Json) -> Result[Void]
  line.subscriptions.delete(identifier)
  Hub.count(line.mount.hub, Hub.SUBSCRIPTIONS, -1)
  case handler.unsubscribed.call(session(line), params)
    error(reason) -> IO.warn("bond-channels: unsubscribed failed: #{reason}")
    ok(_) -> return ok()
  end

  return ok()
end

def unsubscribe(line: Line, identifier: String) -> Result[Void]
  channel = line.subscriptions.get(identifier)
  if not channel.ok?
    IO.warn("bond-channels: no subscription #{identifier}")
    return ok()
  end

  # It waits for room in the hub inbox as `attached?` does: a lost message would leave the hub routing the broadcasts
  # of this identifier to the connection. Nothing more can be done for a hub that does not answer: `Disconnect` settles
  # it when the connection ends.
  detached = Hub.detach(line.mount.hub, line.connection, identifier)
  if not detached.ok?
    IO.warn("bond-channels: the hub did not take the unsubscribe of #{identifier}: #{detached.message}")
  end

  return release(line, channel.unwrap!, identifier)
end

# `unsubscribed` for a subscription that is in the table, and out of it.
def release(line: Line, channel: String, identifier: String) -> Result[Void]
  params = try Protocol.identifier_params(identifier)
  case line.mount.options.handlers.get(channel)
    none -> return ok()
    some(handler) -> return forget(line, handler, identifier, params)
  end
end

def perform(line: Line, action: Protocol.Action) -> Result[Void]
  channel = line.subscriptions.get(action.identifier)
  if not channel.ok?
    IO.warn("bond-channels: no subscription #{action.identifier}")
    return ok()
  end

  params = try Protocol.identifier_params(action.identifier)
  case line.mount.options.handlers.get(channel.unwrap!)
    none -> return ok()
    some(handler) ->
      case handler.perform.call(session(line), params, action.name, action.data)
        ok(payloads) -> return transmit(line, action.identifier, payloads)
        error(reason) ->
          IO.warn("bond-channels: #{channel.unwrap!} #{action.name} failed: #{reason}")
          return ok()
      end
  end
end

# On every exit (a close, a drop, a crash of the loop): `unsubscribed` for each subscription, each in a task of its own
# so that a crash of one handler does not stop the others. Presence depends on it. The hub is not told per
# subscription: `Disconnect`, which follows, removes all the keys of the connection.
def finish(line: Line) -> Void
  for identifier in line.subscriptions.keys
    channel = line.subscriptions.get(identifier).unwrap_or("")
    outcome = Task.await(Task.spawn() do release(line, channel, identifier) end)
    if not outcome.ok?
      IO.warn("bond-channels: leaving #{identifier} failed: #{outcome.message}")
    end
  end
end

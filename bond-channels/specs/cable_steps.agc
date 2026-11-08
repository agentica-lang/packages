## The steps of `cable.feature`. The server is the program of `fixtures/server.agc`; the peer is
## `fixtures/cable_peer.py`, a raw-socket WebSocket client that a step drives with one JSON line per command (it keeps
## the connections open). A step may halt on what is not the scenario's business (the peer does not answer): that
## fails the scenario.

import BDD from "std/bdd"
import HTTP from "std/http"

PORT = "port"
PEER = "peer"
SERVER = "fixtures/server.agc"
# Relative to the working directory of the run, which is the package folder (`make test`).
PEER_PROGRAM = "specs/fixtures/cable_peer.py"
START_MS = 10_000
ANSWER_MS = 15_000
RECEIVE_MS = 5_000
# The most frames that a scenario skips between two that it waits for (a fast ping may fill the gap).
SKIPPED_FRAMES = 400
STATS_TRIES = 300
STATS_WAIT_MS = 10
SOCKET_HEADER = "Sec-WebSocket-Protocol"

struct Order
  op: String
  id: String = ""
  path: String = ""
  headers: Map[String, String] = {}
  protocols: String = ""
  text: String = ""
  timeout_ms: Int = 0
end

export def steps() -> List[BDD.Step]
  return [
    BDD.step("the cable server listens on a free port", &listens),
    BDD.step("client {string} connects with:", &connects),
    BDD.step("the handshake of {string} is answered {int}", &handshake_is),
    BDD.step("client {string} sends:", &sends),
    BDD.step("client {string} sends a text of {int} bytes", &sends_bytes),
    BDD.step("client {string} subscribes to the room {string}", &subscribes),
    BDD.step("client {string} subscribes to the Turbo stream {string}", &subscribes_to_turbo),
    BDD.step("client {string} subscribes to the Turbo stream with the signed name {string}", &subscribes_signed),
    BDD.step("client {string} performs {string} in the room {string}", &performs),
    BDD.step("client {string} says {string} in the room {string}", &says),
    BDD.step("client {string} receives:", &receives),
    BDD.step("client {string} eventually receives a frame containing {string}", &eventually_receives),
    BDD.step("client {string} receives nothing for {int} milliseconds", &receives_nothing),
    BDD.step("client {string} is closed by the server with the code {int}", &closed_with),
    BDD.step("client {string} closes", &closes),
    BDD.step("client {string} drops the connection", &drops),
    BDD.step("client {string} receives the confirmation before any broadcast", &confirmed_first),
    BDD.step("the app broadcasts {string} to {string}", &broadcasts),
    BDD.step("the app broadcasts {string} to {string} {int} times", &broadcasts_often),
    BDD.step("the app cannot broadcast {string} to {string}", &cannot_broadcast),
    BDD.step("the app stops the hub", &stops_hub),
    BDD.step("the app disconnects {string} with reconnect {string}", &disconnects),
    BDD.step("{int} milliseconds pass", &waits),
    BDD.step("the stats become:", &stats_become),
  ]
end

def ask(process: Process, request: Json) -> Result[Json]
  try Process.send(process, JSON.encode(request) + "\n", ANSWER_MS)
  line = try Process.read_line(process, ANSWER_MS)
  return JSON.parse(line)
end

def serving(f: Fn[Json, Result[Json]]) -> Fn[Json, Result[Json]]
  return f
end

def listens(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  started = BDD.given_program(ctx, SERVER)
  line = BDD.read_line(started, START_MS).unwrap!
  port = line.split(" ").last.to_i!
  process = Process.spawn_captured("python3", [PEER_PROGRAM, "#{port}"]).unwrap!
  service = serving() do |request| ask(process, request) end
  return BDD.set(BDD.keep(started, PEER, service), PORT, JSON.from(port))
end

def port_of(ctx: BDD.Context) -> Int
  return JSON.int(BDD.get(ctx, PORT).unwrap!).unwrap!
end

def peer(ctx: BDD.Context, order: Order) -> Json
  return BDD.call(ctx, PEER, JSON.from(order)).unwrap!
end

def text_of(answer: Json, name: String) -> String
  return JSON.string(JSON.get(answer, name).unwrap_or(JSON.from(""))).unwrap_or("")
end

def int_of(answer: Json, name: String) -> Int
  return JSON.int(JSON.get(answer, name).unwrap_or(JSON.from(0))).unwrap_or(0)
end

def has?(answer: Json, name: String) -> Bool
  return JSON.get(answer, name).ok?
end

# The rows of the table are `| header | value |` after a title row; PORT in a value is the port of the server.
def connects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  headers: Map[String, String] = {}
  protocols = ""
  for row in BDD.table(ctx).drop(1)
    value = row[1].replace("PORT", "#{port_of(ctx)}")
    if row[0] == SOCKET_HEADER
      protocols = value
    else
      headers = headers.put(row[0], value)
    end
  end

  answer = peer(ctx, Order(op: "connect", id: args[0], path: "/cable", headers: headers, protocols: protocols))
  return BDD.set(ctx, "status #{args[0]}", JSON.get(answer, "status").unwrap!)
end

def handshake_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  status = JSON.int(BDD.get(ctx, "status #{args[0]}").unwrap!).unwrap!
  return BDD.assert(ctx, status == args[1].to_i!, "the handshake of #{args[0]} was answered #{status}")
end

def sends(ctx: BDD.Context, args: List[String]) -> BDD.Context
  _ = peer(ctx, Order(op: "send", id: args[0], text: BDD.doc_string(ctx)))
  return ctx
end

def sends_bytes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  _ = peer(ctx, Order(op: "send", id: args[0], text: "x" * args[1].to_i!))
  return ctx
end

def room_identifier(room: String) -> String
  return "{\"channel\":\"RoomChannel\",\"room\":\"#{room}\"}"
end

def send_command(ctx: BDD.Context, id: String, command: Json) -> BDD.Context
  _ = peer(ctx, Order(op: "send", id: id, text: JSON.encode(command)))
  return ctx
end

def subscribes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  command = JSON.from({"command": JSON.from("subscribe"), "identifier": JSON.from(room_identifier(args[1]))})
  return send_command(ctx, args[0], command)
end

# The page of the app would carry the signed name: here the server signs it, as `GET /signed` of the fixture.
def subscribes_to_turbo(ctx: BDD.Context, args: List[String]) -> BDD.Context
  answer = HTTP.get_response("http://127.0.0.1:#{port_of(ctx)}/signed?name=#{args[1]}").unwrap!
  return subscribe_to_signed(ctx, args[0], answer.body.decode("utf-8").unwrap!)
end

def subscribes_signed(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return subscribe_to_signed(ctx, args[0], args[1])
end

# The identifier that `<turbo-cable-stream-source>` makes for the Rails client.
def subscribe_to_signed(ctx: BDD.Context, id: String, signed: String) -> BDD.Context
  identifier = JSON.encode({"channel": "Turbo::StreamsChannel", "signed_stream_name": signed})
  command = JSON.from({"command": JSON.from("subscribe"), "identifier": JSON.from(identifier)})
  return send_command(ctx, id, command)
end

def message_command(room: String, data: Json) -> Json
  return JSON.from({
    "command": JSON.from("message"),
    "identifier": JSON.from(room_identifier(room)),
    "data": JSON.from(JSON.encode(data)),
  })
end

def performs(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = JSON.from({"action": JSON.from(args[1])})
  return send_command(ctx, args[0], message_command(args[2], data))
end

def says(ctx: BDD.Context, args: List[String]) -> BDD.Context
  data = JSON.from({"action": JSON.from("say"), "text": JSON.from(args[1])})
  return send_command(ctx, args[0], message_command(args[2], data))
end

def next_frame(ctx: BDD.Context, id: String, timeout_ms: Int) -> Json
  return peer(ctx, Order(op: "recv", id: id, timeout_ms: timeout_ms))
end

def receives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  frame = next_frame(ctx, args[0], RECEIVE_MS)
  expected = BDD.doc_string(ctx)
  return BDD.assert(ctx, text_of(frame, "text") == expected, "#{args[0]} got #{frame}, expected #{expected}")
end

# Skips what comes before (a ping, a frame of another scenario step): a scenario states what it must hear.
def eventually_receives(ctx: BDD.Context, args: List[String]) -> BDD.Context
  for _skipped in 1..SKIPPED_FRAMES
    frame = next_frame(ctx, args[0], RECEIVE_MS)
    if text_of(frame, "text").include?(args[1])
      return BDD.assert(ctx, true, "")
    end

    if not has?(frame, "text")
      return BDD.assert(ctx, false, "#{args[0]} got #{frame} before a frame with #{args[1]}")
    end
  end

  return BDD.assert(ctx, false, "#{args[0]} heard no frame with #{args[1]} in #{SKIPPED_FRAMES} frames")
end

# A broadcast that the hub handles before the subscription is attached is not heard at all, which is fine; one that
# comes after must not pass the confirmation, which the connection writes before it reads its inbox again.
def confirmed_first(ctx: BDD.Context, args: List[String]) -> BDD.Context
  for _skipped in 1..SKIPPED_FRAMES
    frame = next_frame(ctx, args[0], RECEIVE_MS)
    text = text_of(frame, "text")
    if text.include?("confirm_subscription")
      return BDD.assert(ctx, true, "")
    end

    if text.include?("\"message\"") or not has?(frame, "text")
      return BDD.assert(ctx, false, "#{args[0]} got #{frame} before the confirmation")
    end
  end

  return BDD.assert(ctx, false, "#{args[0]} heard no confirmation in #{SKIPPED_FRAMES} frames")
end

def receives_nothing(ctx: BDD.Context, args: List[String]) -> BDD.Context
  frame = next_frame(ctx, args[0], args[1].to_i!)
  return BDD.assert(ctx, has?(frame, "timeout"), "#{args[0]} got #{frame}, expected nothing")
end

def closed_with(ctx: BDD.Context, args: List[String]) -> BDD.Context
  for _skipped in 1..SKIPPED_FRAMES
    frame = next_frame(ctx, args[0], RECEIVE_MS)
    if not has?(frame, "text")
      code = int_of(frame, "closed")
      return BDD.assert(ctx, code == args[1].to_i!, "#{args[0]} was closed with #{code} (#{frame})")
    end
  end

  return BDD.assert(ctx, false, "#{args[0]} was not closed")
end

def closes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  _ = peer(ctx, Order(op: "close", id: args[0]))
  return ctx
end

def drops(ctx: BDD.Context, args: List[String]) -> BDD.Context
  _ = peer(ctx, Order(op: "drop", id: args[0]))
  return ctx
end

def broadcasts(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = "http://127.0.0.1:#{port_of(ctx)}/say?topic=#{args[1]}&text=#{args[0]}"
  answer = HTTP.get_response(url).unwrap!
  return BDD.assert(ctx, answer.status == 200, "the broadcast was answered #{answer.status}")
end

# One after the other, each answered before the next: the first may reach the hub before the subscriptions do.
def broadcasts_often(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = "http://127.0.0.1:#{port_of(ctx)}/say?topic=#{args[1]}&text=#{args[0]}"
  for _ in 1..args[2].to_i!
    answer = HTTP.get_response(url).unwrap!
    if answer.status != 200
      return BDD.assert(ctx, false, "the broadcast was answered #{answer.status}")
    end
  end

  return BDD.assert(ctx, true, "")
end

# A broadcast to a hub that is gone is an `error`, which the HTTP handler turns into a 500.
def cannot_broadcast(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = "http://127.0.0.1:#{port_of(ctx)}/say?topic=#{args[1]}&text=#{args[0]}"
  answer = HTTP.get_response(url).unwrap!
  return BDD.assert(ctx, answer.status == 500, "the broadcast was answered #{answer.status}, expected 500")
end

def disconnects(ctx: BDD.Context, args: List[String]) -> BDD.Context
  url = "http://127.0.0.1:#{port_of(ctx)}/disconnect?user=#{args[0]}&reconnect=#{args[1]}"
  answer = HTTP.get_response(url).unwrap!
  return BDD.assert(ctx, answer.status == 200, "the disconnect was answered #{answer.status}")
end

def stops_hub(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  answer = HTTP.get_response("http://127.0.0.1:#{port_of(ctx)}/stop").unwrap!
  return BDD.assert(ctx, answer.status == 200, "the stop was answered #{answer.status}")
end

def waits(ctx: BDD.Context, args: List[String]) -> BDD.Context
  Task.sleep(args[0].to_i!)
  return BDD.assert(ctx, true, "")
end

def canonical(text: String) -> String
  return JSON.encode(JSON.parse(text).unwrap!)
end

# The counters are written by other tasks a moment after the frames that cause them, so it polls.
def stats_become(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  expected = canonical(BDD.doc_string(ctx))
  actual = ""
  for _try in 1..STATS_TRIES
    actual = canonical(
      HTTP.get_response("http://127.0.0.1:#{port_of(ctx)}/stats").unwrap!.body.decode("utf-8").unwrap!,
    )

    if actual == expected
      return BDD.assert(ctx, true, "")
    end

    Task.sleep(STATS_WAIT_MS)
  end

  return BDD.assert(ctx, false, "the stats are #{actual}, expected #{expected}")
end

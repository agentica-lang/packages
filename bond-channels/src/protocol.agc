## The `actioncable-v1-json` frames of Action Cable, as pure functions: the frames a server writes are `String`s of
## compact JSON, and a text frame that a client wrote is read into a `Command`. No socket, task or hub is involved.

## A bigger identifier is not read (Rails has no limit; this one bounds what a socket makes the server hold).
export MAX_IDENTIFIER_BYTES = 4096

RECEIVE = "receive"
UNAUTHORIZED = "unauthorized"

# The field order of these structs is the key order of the frame, as in `Connection::Base` and `Channel::Base`
# of Rails.
struct Typed
  type: String
end

struct Ping
  type: String
  message: Int
end

struct Disconnect
  type: String
  reason: Optional[String]
  reconnect: Bool
end

struct Confirmation
  identifier: String
  type: String
end

## A `subscribe`: `identifier` is the key of the subscription, byte for byte; `channel` is the `channel` of its
## parsed form ("" when there is none or it is not a string) and `params` the parsed object itself.
export struct Join
  identifier: String
  channel: String
  params: Json
end

## A `message`: `name` is the `action` of `data` (`receive` when it is missing or blank), `data` its parsed object.
export struct Action
  identifier: String
  name: String
  data: Json
end

## A command of a client, read by `decode_command`. `Unsubscribe` holds the identifier.
export enum Command
  Subscribe(Join)
  Unsubscribe(String)
  Perform(Action)
end

## `{"type":"welcome"}`, the first frame after the upgrade.
export def welcome() -> String
  return JSON.encode(Typed(type: "welcome"))
end

## `{"type":"ping","message":SECONDS}`, with the Unix time in seconds.
export def ping(unix_seconds: Int) -> String
  return JSON.encode(Ping(type: "ping", message: unix_seconds))
end

## The frame of a `connect` that refuses: the client must not reconnect.
export def disconnect_unauthorized() -> String
  return JSON.encode(Disconnect(type: "disconnect", reason: some(UNAUTHORIZED), reconnect: false))
end

## The frame of a server that drops a connection: the client may reconnect.
export def disconnect_reconnect() -> String
  return JSON.encode(Disconnect(type: "disconnect", reason: none, reconnect: true))
end

## `{"identifier":ID,"type":"confirm_subscription"}`.
export def confirm_subscription(identifier: String) -> String
  return JSON.encode(Confirmation(identifier: identifier, type: "confirm_subscription"))
end

## `{"identifier":ID,"type":"reject_subscription"}`.
export def reject_subscription(identifier: String) -> String
  return JSON.encode(Confirmation(identifier: identifier, type: "reject_subscription"))
end

## The JSON text of a payload that is a string (a Turbo Stream), to give to `message` once per broadcast.
export def text_payload(text: String) -> String
  return JSON.encode(text)
end

## The JSON text of a payload that is an object (a notice), to give to `message` once per broadcast.
export def json_payload(value: Json) -> String
  return JSON.encode(value)
end

## `{"identifier":ID,"message":PAYLOAD}`, where `payload` is the text that `text_payload` or `json_payload` made. The
## payload is spliced in, not encoded again: a broadcast to many subscribers encodes it once.
export def message(identifier: String, payload: String) -> String
  return "{\"identifier\":#{JSON.encode(identifier)},\"message\":#{payload}}"
end

## Reads a text frame of a client. An `error` is the reason to log: Action Cable ignores such a frame and the
## connection stays open.
export def decode_command(text: String) -> Result[Command]
  frame = try JSON.parse(text)
  if JSON.kind(frame) != "object"
    return error("the frame is not a JSON object")
  end

  name = try string_field(frame, "command")
  identifier = try string_field(frame, "identifier")
  case name
    "subscribe" -> return decode_subscribe(identifier)
    "unsubscribe" -> return ok(Command.Unsubscribe(identifier))
    "message" -> return decode_perform(frame, identifier)
    _ -> return error("unrecognized command #{name}")
  end
end

def decode_subscribe(identifier: String) -> Result[Command]
  if identifier.bytes.length > MAX_IDENTIFIER_BYTES
    return error("the identifier is longer than #{MAX_IDENTIFIER_BYTES} bytes")
  end

  params = try JSON.parse(identifier)
  if JSON.kind(params) != "object"
    return error("the identifier is not a JSON object")
  end

  # Rails finds no class for a missing channel and logs it, so a missing or odd one is "" and the hub logs it.
  channel = string_field(params, "channel").unwrap_or("")
  return ok(Command.Subscribe(Join(identifier: identifier, channel: channel, params: params)))
end

# `data` is a JSON string that holds the object (the client encodes it twice).
def decode_perform(frame: Json, identifier: String) -> Result[Command]
  text = try string_field(frame, "data")
  data = try JSON.parse(text)
  if JSON.kind(data) != "object"
    return error("data is not a JSON object")
  end

  name = try action_name(data)
  return ok(Command.Perform(Action(identifier: identifier, name: name, data: data)))
end

# A missing, null or blank action is `receive`, as in Rails; any other kind is refused.
def action_name(data: Json) -> Result[String]
  field = JSON.get(data, "action")
  case field
    ok(value) -> return named_action(value)
    error(_) -> return ok(RECEIVE)
  end
end

def named_action(value: Json) -> Result[String]
  case JSON.kind(value)
    "null" -> return ok(RECEIVE)
    "string" ->
      name = try JSON.string(value)
      if name.strip == ""
        return ok(RECEIVE)
      end

      return ok(name)
    _ -> return error("action is not a string")
  end
end

def string_field(frame: Json, key: String) -> Result[String]
  field = JSON.get(frame, key)
  case field
    ok(value) ->
      case JSON.string(value)
        ok(text) -> return ok(text)
        error(_) -> return error("#{key} is not a string")
      end

    error(_) -> return error("the frame has no #{key}")
  end
end

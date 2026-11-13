## The `actioncable-v1-json` frames of Action Cable, as pure functions: the frames a server writes are `String`s of
## compact JSON, and a text frame that a client wrote is read into a `Command`. No socket, task or hub is involved.

## The only subprotocol that is served.
SUBPROTOCOL = "actioncable-v1-json"
## A bigger identifier is not read (Rails has no limit; this one bounds what a socket makes the server hold).
MAX_IDENTIFIER_BYTES = 4096

## A `subscribe`: `identifier` is the key of the subscription, byte for byte; `channel` is the `channel` of its
## parsed form ("" when there is none or it is not a string) and `params` the parsed object itself.
struct Join
  identifier: String
  channel: String
  params: JSON.Value
end

## A `message`: `name` is the `action` of `data` (`receive` when it is missing or blank), `data` its parsed object.
struct Action
  identifier: String
  name: String
  data: JSON.Value
end

## A command of a client, read by `decode_command`. `Unsubscribe` holds the identifier.
enum Command
  Subscribe(Join)
  Unsubscribe(String)
  Perform(Action)
end

## `{"type":"welcome"}`, the first frame after the upgrade.
def welcome() -> String = JSON.encode(Typed(type: "welcome"))

## `{"type":"ping","message":SECONDS}`, with the Unix time in seconds.
def ping(unix_seconds: Int) -> String = JSON.encode(Ping(type: "ping", message: unix_seconds))

## The frame of a `connect` that refuses: the client must not reconnect.
def disconnect_unauthorized() -> String
  JSON.encode(Disconnect(type: "disconnect", reason: some(UNAUTHORIZED), reconnect: false))
end

## The frame of a server that drops a connection: the client may reconnect.
def disconnect_reconnect() -> String = JSON.encode(Disconnect(type: "disconnect", reason: none, reconnect: true))

## The frame of a server that ends the connections of a person on purpose (`Channels.disconnect`, the
## `remote_connections.disconnect` of Rails): the client reconnects only when `reconnect` is true.
def disconnect_remote(reconnect: Bool) -> String
  JSON.encode(Disconnect(type: "disconnect", reason: some(REMOTE), reconnect: reconnect))
end

## `{"identifier":ID,"type":"confirm_subscription"}`.
def confirm_subscription(identifier: String) -> String
  JSON.encode(Confirmation(identifier: identifier, type: "confirm_subscription"))
end

## `{"identifier":ID,"type":"reject_subscription"}`.
def reject_subscription(identifier: String) -> String
  JSON.encode(Confirmation(identifier: identifier, type: "reject_subscription"))
end

## The JSON text of a payload that is a string (a Turbo Stream), to give to `message` once per broadcast.
def text_payload(text: String) -> String = JSON.encode(text)

## The JSON text of a payload that is an object (a notice), to give to `message` once per broadcast. A parsed object
## comes out with its keys sorted, and one made by `JSON.object` or `JSON.from` in no fixed order.
def json_payload(value: JSON.Value) -> String = JSON.encode(value)

## `{"identifier":ID,"message":PAYLOAD}`, where `payload` is the text that `text_payload` or `json_payload` made. The
## payload is spliced in, not encoded again: a broadcast to many subscribers encodes it once.
def message(identifier: String, payload: String) -> String
  "{\"identifier\":#{JSON.encode(identifier)},\"message\":#{payload}}"
end

## Reads a text frame of a client. An `error` is the reason to log: Action Cable ignores such a frame and the
## connection stays open.
def decode_command(text: String) -> Result[Command]
  frame = try parsed_object(text, "the frame")
  name = try string_field(frame, "command")
  identifier = try string_field(frame, "identifier")
  case name
    "subscribe" -> decode_subscribe(identifier)
    "unsubscribe" -> ok(Command.Unsubscribe(identifier))
    "message" -> decode_perform(frame, identifier)
    _ -> error("unrecognized command #{name}")
  end
end

## The parsed identifier of a subscription that `decode_command` accepted.
def identifier_params(identifier: String) -> Result[JSON.Value] = parsed_object(identifier, "the identifier")

private

RECEIVE = "receive"
UNAUTHORIZED = "unauthorized"
REMOTE = "remote"
# The characters of Ruby's `[[:space:]]`, which `String#blank?` of Rails tests; `strip` knows only the ASCII ones.
SPACE_CODES = Set.new([9, 10, 11, 12, 13, 32, 133, 160, 5760, 8232, 8233, 8239, 8287, 12288])
EN_SPACES = 8192..8202

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

def decode_subscribe(identifier: String) -> Result[Command]
  if identifier.bytes.length > MAX_IDENTIFIER_BYTES
    return error("the identifier is longer than #{MAX_IDENTIFIER_BYTES} bytes")
  end

  params = try identifier_params(identifier)
  # Rails finds no class for a missing channel and logs it, so a missing or odd one is "" and the hub logs it.
  channel = string_field(params, "channel").unwrap_or("")
  ok(Command.Subscribe(Join(identifier: identifier, channel: channel, params: params)))
end

# `data` is a JSON string that holds the object (the client encodes it twice).
def decode_perform(frame: JSON.Value, identifier: String) -> Result[Command]
  text = try string_field(frame, "data")
  data = try parsed_object(text, "data")
  name = try action_name(data)
  ok(Command.Perform(Action(identifier: identifier, name: name, data: data)))
end

# A missing, null or blank action (Unicode spaces count as blank) is `receive`; any other kind is refused, as the Rust
# port does. Rails is looser: `false`, `[]` and `{}` are blank to it, and `5` is the action "5".
def action_name(data: JSON.Value) -> Result[String]
  field = JSON.get(data, "action")
  case field
    ok(value) -> named_action(value)
    error(_) -> ok(RECEIVE)
  end
end

def named_action(value: JSON.Value) -> Result[String]
  case JSON.kind(value)
    "null" -> ok(RECEIVE)
    "string" ->
      name = try JSON.string(value)
      return ok(RECEIVE) if blank?(name)

      ok(name)
    _ -> error("action is not a string")
  end
end

def blank?(text: String) -> Bool
  for char in text.split("")
    code = char.code
    return false if not SPACE_CODES.include?(code) and not EN_SPACES.include?(code)
  end

  true
end

# `what` names the text in the reason that the caller logs.
def parsed_object(text: String, what: String) -> Result[JSON.Value]
  case JSON.parse(text)
    ok(value) ->
      return error("#{what} is not a JSON object") if JSON.kind(value) != "object"

      ok(value)
    error(_) -> error("#{what} is not JSON")
  end
end

def string_field(frame: JSON.Value, key: String) -> Result[String]
  field = JSON.get(frame, key)
  case field
    ok(value) ->
      case JSON.string(value)
        ok(text) -> ok(text)
        error(_) -> error("#{key} is not a string")
      end

    error(_) -> error("the frame has no #{key}")
  end
end

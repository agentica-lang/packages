## The steps of the features: the frames of `src/protocol.agc`, written and read as text. Nothing here opens a socket.

import BDD from "std/bdd"
import Cable from "cable_steps"
import Protocol from "../src/protocol"

IDENTIFIER = "identifier"
PAYLOAD = "payload"
READ = "read"
IGNORED = "ignored"

def given_identifier(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return BDD.set(ctx, IDENTIFIER, JSON.from(BDD.doc_string(ctx)))
end

def given_text_payload(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return BDD.set(ctx, PAYLOAD, JSON.from(Protocol.text_payload(BDD.doc_string(ctx))))
end

def given_object_payload(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  case JSON.parse(BDD.doc_string(ctx))
    ok(value) -> return BDD.set(ctx, PAYLOAD, JSON.from(Protocol.json_payload(value)))
    error(reason) -> return BDD.assert(ctx, false, "the payload is not JSON: #{reason}")
  end
end

def remembered(ctx: BDD.Context, name: String) -> String
  case BDD.get(ctx, name)
    ok(value) -> return JSON.string(value).unwrap_or("")
    error(_) -> return ""
  end
end

def frame_is(ctx: BDD.Context, actual: String) -> BDD.Context
  expected = BDD.doc_string(ctx)
  return BDD.assert(ctx, actual == expected, "the frame is #{actual}, expected #{expected}")
end

def welcome_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.welcome())
end

def ping_is(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.ping(args[0].to_i!))
end

def confirmation_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.confirm_subscription(remembered(ctx, IDENTIFIER)))
end

def rejection_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.reject_subscription(remembered(ctx, IDENTIFIER)))
end

def unauthorized_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.disconnect_unauthorized())
end

def reconnect_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.disconnect_reconnect())
end

def message_is(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return frame_is(ctx, Protocol.message(remembered(ctx, IDENTIFIER), remembered(ctx, PAYLOAD)))
end

# What the server read, as the JSON of its fields: the one form that the Then step can compare with a Doc String.
def described(command: Protocol.Command) -> Json
  case command
    Protocol.Command.Subscribe(join) ->
      return JSON.from({
        "command": JSON.from("subscribe"),
        "identifier": JSON.from(join.identifier),
        "channel": JSON.from(join.channel),
        "params": join.params,
      })
    Protocol.Command.Unsubscribe(identifier) ->
      return JSON.from({"command": JSON.from("unsubscribe"), "identifier": JSON.from(identifier)})
    Protocol.Command.Perform(action) ->
      return JSON.from({
        "command": JSON.from("message"),
        "identifier": JSON.from(action.identifier),
        "action": JSON.from(action.name),
        "data": action.data,
      })
  end
end

def client_sends(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  return read_frame(ctx, BDD.doc_string(ctx))
end

# A client that wraps `data` in a string, as `@rails/actioncable` does: the Doc String has no escapes to write by hand.
def client_sends_data(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  frame = "{\"command\":\"message\",\"identifier\":\"{}\",\"data\":#{JSON.encode(BDD.doc_string(ctx))}}"
  return read_frame(ctx, frame)
end

def read_frame(ctx: BDD.Context, frame: String) -> BDD.Context
  case Protocol.decode_command(frame)
    ok(command) -> return BDD.set(ctx, READ, JSON.from(canonical(described(command))))
    error(reason) -> return BDD.set(ctx, IGNORED, JSON.from(reason))
  end
end

# Both sides go through `JSON.parse`, which writes the keys in one order, so the order of the Doc String is free.
def canonical(value: Json) -> String
  return JSON.encode(JSON.parse(JSON.encode(value)).unwrap!)
end

def server_reads(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  expected = JSON.parse(BDD.doc_string(ctx)).unwrap!
  actual = remembered(ctx, READ)
  return BDD.assert(ctx, actual == canonical(expected), "the server read #{actual}, expected #{canonical(expected)}")
end

def server_ignores(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reason = remembered(ctx, IGNORED)
  return BDD.assert(ctx, reason == args[0], "the frame was ignored for \"#{reason}\", expected \"#{args[0]}\"")
end

# A step that reads what the previous step wrote may halt: a crash fails the scenario, which is what a bad
# feature needs.
def confirmation_of_read(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  read = JSON.parse(remembered(ctx, READ)).unwrap!
  identifier = JSON.get(read, "identifier").unwrap!
  return frame_is(ctx, Protocol.confirm_subscription(JSON.string(identifier).unwrap!))
end

def main() -> Void
  frames = [
    BDD.step("the identifier:", &given_identifier),
    BDD.step("the text payload:", &given_text_payload),
    BDD.step("the object payload:", &given_object_payload),
    BDD.step("the welcome frame is:", &welcome_is),
    BDD.step("the ping frame at {int} is:", &ping_is),
    BDD.step("the confirmation is:", &confirmation_is),
    BDD.step("the rejection is:", &rejection_is),
    BDD.step("the unauthorized disconnect is:", &unauthorized_is),
    BDD.step("the reconnecting disconnect is:", &reconnect_is),
    BDD.step("the message is:", &message_is),
    BDD.step("the client sends:", &client_sends),
    BDD.step("the client sends a message whose data is:", &client_sends_data),
    BDD.step("the server reads:", &server_reads),
    BDD.step("the server ignores it because {string}", &server_ignores),
    BDD.step("the confirmation of that subscribe is:", &confirmation_of_read),
  ]

  BDD.run(frames.concat(Cable.steps()))
end

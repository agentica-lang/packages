## The steps of wire.feature: the frames are written and read by the codec of `src/wire.agc`. A message is spelled in
## words (`ping`, `bye done`, `mail jobs hello`) and what a step reads is kept as a JSON line of the context.

import BDD from "std/bdd"
import Binary from "std/binary"
import Types from "../src/types"
import Wire from "../src/wire"

def main() -> Void
  BDD.run([
    BDD.step("a node writes the message {string}", &writes_message),
    BDD.step("another node reads {string}", &reads_message),
    BDD.step("a node reads the greeting {string}", &reads_greeting),
    BDD.step("a node reads the greeting that a node writes", &reads_own_greeting),
    BDD.step("a frame says it has {int} bytes and the limit is {int}", &frame_says),
    BDD.step("a node writes a mail of {int} bytes for the mailbox {string} with a limit of {int}", &writes_big_mail),
    BDD.step("a node writes a mail for a mailbox of {int} bytes", &writes_mailbox),
    BDD.step("the frame loses its last {int} bytes", &loses_bytes),
    BDD.step("the frame gets {int} more bytes", &gets_bytes),
    BDD.step("the frame is cut to its first {int} bytes", &is_cut),
    BDD.step("a node reads a frame of the kind {int}", &reads_kind),
    BDD.step("another node refuses it as {string}", &frame_refused_as),
    BDD.step("it is refused as {string}", &refused_as),
    BDD.step("it is accepted", &accepted),
    BDD.step("it is ignored", &ignored),
  ])
end

private

FRAME = "frame"
OUTCOME = "outcome"
EMPTY_MAP = 0xa0

# What a step read: whether it was accepted, the text of the message or the kind of the error.
struct Outcome
  accepted: Bool
  text: String
  kind: String
end

def message_of(spelled: String) -> Types.Message
  words = spelled.split(" ")
  case words[0]
    "ping" -> Types.Message.Ping
    "pong" -> Types.Message.Pong
    "bye" -> Types.Message.Bye(words.drop(1).join(" "))
    _ -> Types.Message.Mail(words[1], words.drop(2).join(" ").bytes)
  end
end

def spelled(message: Types.Message) -> String
  case message
    Types.Message.Ping -> "ping"
    Types.Message.Pong -> "pong"
    Types.Message.Bye(reason) -> "bye #{reason}".strip
    Types.Message.Mail(mailbox, body) -> "mail #{mailbox} #{String.from_bytes(body).unwrap!}".strip
    Types.Message.Ignored(kind) -> "ignored #{kind}"
  end
end

def keep_frame(ctx: BDD.Context, frame: Bytes) -> BDD.Context
  BDD.set(ctx, FRAME, JSON.from(OpenSSL.Digest.hexencode(frame)))
end

def frame_of(ctx: BDD.Context) -> Bytes
  OpenSSL.Digest.hexdecode(JSON.string(BDD.get(ctx, FRAME).unwrap!).unwrap!).unwrap!
end

def keep_outcome(ctx: BDD.Context, outcome: Outcome) -> BDD.Context = BDD.set(ctx, OUTCOME, JSON.from(outcome))

def outcome_of(ctx: BDD.Context) -> Outcome = Outcome.codec.decode(BDD.get(ctx, OUTCOME).unwrap!).unwrap!

def read_outcome(result: Result[Types.Message]) -> Outcome
  case result
    ok(message) -> Outcome(accepted: true, text: spelled(message), kind: "")
    error(e) -> Outcome(accepted: false, text: "", kind: e.kind)
  end
end

def check_outcome[T](result: Result[T]) -> Outcome
  case result
    ok(_) -> Outcome(accepted: true, text: "", kind: "")
    error(e) -> Outcome(accepted: false, text: "", kind: e.kind)
  end
end

def writes_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_frame(ctx, Wire.encode(message_of(args[0])).unwrap!)
end

def reads_message(ctx: BDD.Context, args: List[String]) -> BDD.Context
  outcome = read_outcome(Wire.read(frame_of(ctx), Types.MAX_FRAME_BYTES))
  BDD.assert(ctx, outcome.text == args[0], "read #{outcome.text} (#{outcome.kind}) and not #{args[0]}")
end

def reads_greeting(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_outcome(ctx, check_outcome(Wire.check_preamble(args[0].bytes)))
end

def reads_own_greeting(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  keep_outcome(ctx, check_outcome(Wire.check_preamble(Wire.preamble())))
end

def frame_says(ctx: BDD.Context, args: List[String]) -> BDD.Context
  header = Binary.write_u32_be(args[0].to_i!.to_uint32!)
  keep_outcome(ctx, check_outcome(Wire.frame_length(header, args[1].to_i!)))
end

def writes_big_mail(ctx: BDD.Context, args: List[String]) -> BDD.Context
  body = Bytes.from_list((1..args[0].to_i!).map { |_| 7 }).unwrap!
  message = Types.Message.Mail(args[1], body)
  keep_outcome(ctx, check_outcome(Wire.encode(message, args[2].to_i!)))
end

def writes_mailbox(ctx: BDD.Context, args: List[String]) -> BDD.Context
  mailbox = (1..args[0].to_i!).map { |_| "a" }.join("")
  keep_outcome(ctx, check_outcome(Wire.encode(Types.Message.Mail(mailbox, "x".bytes))))
end

def loses_bytes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  frame = frame_of(ctx)
  keep_frame(ctx, frame.take(frame.size - args[0].to_i!))
end

def gets_bytes(ctx: BDD.Context, args: List[String]) -> BDD.Context
  keep_frame(ctx, frame_of(ctx) + Bytes.from_list((1..args[0].to_i!).map { |_| 0 }).unwrap!)
end

def is_cut(ctx: BDD.Context, args: List[String]) -> BDD.Context = keep_frame(ctx, frame_of(ctx).take(args[0].to_i!))

def reads_kind(ctx: BDD.Context, args: List[String]) -> BDD.Context
  payload = Bytes.from_list([args[0].to_i!, EMPTY_MAP]).unwrap!
  frame = Binary.frame(payload).unwrap!
  keep_outcome(ctx, read_outcome(Wire.read(frame, Types.MAX_FRAME_BYTES)))
end

def refused_as(ctx: BDD.Context, args: List[String]) -> BDD.Context = refused(ctx, outcome_of(ctx), args[0])

def frame_refused_as(ctx: BDD.Context, args: List[String]) -> BDD.Context
  refused(ctx, read_outcome(Wire.read(frame_of(ctx), Types.MAX_FRAME_BYTES)), args[0])
end

def refused(ctx: BDD.Context, outcome: Outcome, kind: String) -> BDD.Context
  BDD.assert(ctx, not outcome.accepted and outcome.kind == kind, "got #{outcome.kind} and not #{kind}")
end

def accepted(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  outcome = outcome_of(ctx)
  BDD.assert(ctx, outcome.accepted and not outcome.text.start_with?("ignored"), "refused as #{outcome.kind}")
end

def ignored(ctx: BDD.Context, _args: List[String]) -> BDD.Context
  outcome = outcome_of(ctx)
  BDD.assert(ctx, outcome.accepted and outcome.text.start_with?("ignored"), "read #{outcome.text} (#{outcome.kind})")
end

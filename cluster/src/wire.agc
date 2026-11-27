## The wire format of a connection (docs/protocol.md): a preamble, then frames. A frame is the length of what follows
## in 4 bytes, one byte for the kind, and the body, the Term CBOR of a struct that each kind has. Everything here is a
## pure function on `Bytes`: the length is checked before the body is read, and bytes from the network never halt it.

import Binary from "std/binary"
import Types from "types"

## The 6 bytes that each side writes first: the magic `AGCN` and the major version of the protocol.
def preamble() -> Bytes = "AGCN".bytes + Bytes.from_list([0, VERSION]).unwrap!

## Checks the 6 bytes that a peer wrote first. Anything else (an HTTP request, a port scan, another version) is a
## `cluster.protocol` error, so the socket can be closed at once.
def check_preamble(data: Bytes) -> Result[Void]
  return protocol("the preamble is not the one of a cluster node") if data != preamble()

  ok()
end

## The length that a 4-byte header says, checked against `max_bytes` before the body is read. A zero is a
## `cluster.protocol` error and a length over the limit is `cluster.too_large`.
def frame_length(header: Bytes, max_bytes: Int) -> Result[Int]
  return protocol("a frame header has 4 bytes, not #{header.size}") if header.size != HEADER_BYTES

  length = (try Binary.read_u32_be(header, 0)).to_i
  return protocol("a frame has no kind") if length == 0
  return too_large(length, max_bytes) if length > max_bytes

  ok(length)
end

## The bytes of one message as a frame: the length, the kind and the body. A frame over `max_bytes` is
## `cluster.too_large`; `Ignored` is only read, never written.
def encode(message: Types.Message, max_bytes: Int = Types.MAX_FRAME_BYTES) -> Result[Bytes]
  payload = try payload_of(message)
  return too_large(payload.size, max_bytes) if payload.size > max_bytes

  Binary.frame(payload)
end

## Reads the payload of a frame (the kind and the body, with no length) as a message. A kind that this version does
## not know is a `cluster.protocol` error, except the kinds 64 to 127, which read as `Ignored`.
def decode(payload: Bytes) -> Result[Types.Message]
  return protocol("a frame has no kind") if payload.empty?

  kind = payload[0]
  body = payload.drop(1)
  return ok(Types.Message.Ignored(kind)) if IGNORABLE.include?(kind)

  case kind
    _ if kind == KIND_PING -> empty(body, Types.Message.Ping)
    _ if kind == KIND_PONG -> empty(body, Types.Message.Pong)
    _ if kind == KIND_BYE -> bye(body)
    _ if kind == KIND_MAIL -> mail(body)
    _ -> protocol("unknown frame kind #{kind}")
  end
end

## Reads one whole frame, the length and its payload, as a message: the way to read the bytes of a buffer. The length
## must match the bytes and stay within `max_bytes`.
def read(frame: Bytes, max_bytes: Int) -> Result[Types.Message]
  length = try frame_length(frame.take(HEADER_BYTES), max_bytes)
  if length != frame.size - HEADER_BYTES
    return protocol("the frame says #{length} bytes and has #{frame.size - HEADER_BYTES}")
  end

  decode(frame.drop(HEADER_BYTES))
end

private

VERSION = 1
HEADER_BYTES = 4
KIND_MAIL = 5
KIND_PING = 6
KIND_PONG = 7
KIND_BYE = 8
IGNORABLE = 64..127

struct Empty
end

struct ByeBody
  reason: String
end

struct MailBody
  mailbox: String
  body: Bytes
end

def protocol[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.PROTOCOL)

def too_large[T](length: Int, max_bytes: Int) -> Result[T]
  error("cluster: a frame of #{length} bytes is over the limit of #{max_bytes}", kind: Types.TOO_LARGE)
end

def payload_of(message: Types.Message) -> Result[Bytes]
  case message
    Types.Message.Ping -> with_kind(KIND_PING, Term.encode(Empty()))
    Types.Message.Pong -> with_kind(KIND_PONG, Term.encode(Empty()))
    Types.Message.Bye(reason) -> with_kind(KIND_BYE, Term.encode(ByeBody(reason: reason)))
    Types.Message.Mail(mailbox, body) -> mail_payload(mailbox, body)
    Types.Message.Ignored(_) -> protocol("a frame of an ignored kind is never written")
  end
end

def mail_payload(mailbox: String, body: Bytes) -> Result[Bytes]
  try check_mailbox(mailbox)
  with_kind(KIND_MAIL, Term.encode(MailBody(mailbox: mailbox, body: body)))
end

def with_kind(kind: Int, body: Result[Bytes]) -> Result[Bytes]
  case body
    ok(encoded) -> ok(Bytes.from_list([kind]).unwrap! + encoded)
    error(e) -> protocol("cannot encode the body: #{e.message}")
  end
end

def check_mailbox(mailbox: String) -> Result[Void]
  return protocol("a mailbox name has 1 to #{Types.MAX_MAILBOX_BYTES} bytes") if mailbox.bytes.empty?
  if mailbox.bytes.size > Types.MAX_MAILBOX_BYTES
    return protocol("a mailbox name has 1 to #{Types.MAX_MAILBOX_BYTES} bytes")
  end

  ok()
end

def empty(body: Bytes, message: Types.Message) -> Result[Types.Message]
  case Term.decode(body, Empty)
    ok(_) -> ok(message)
    error(e) -> protocol("a ping or a pong with a bad body: #{e.message}")
  end
end

def bye(body: Bytes) -> Result[Types.Message]
  case Term.decode(body, ByeBody)
    ok(b) -> ok(Types.Message.Bye(b.reason))
    error(e) -> protocol("a bye with a bad body: #{e.message}")
  end
end

def mail(body: Bytes) -> Result[Types.Message]
  decoded = Term.decode(body, MailBody)
  case decoded
    ok(m) -> mail_of(m)
    error(e) -> protocol("a mail with a bad body: #{e.message}")
  end
end

def mail_of(m: MailBody) -> Result[Types.Message]
  try check_mailbox(m.mailbox)
  ok(Types.Message.Mail(m.mailbox, m.body))
end

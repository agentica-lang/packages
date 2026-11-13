## The wire format of RFC 6455 for a client: the frames it writes (always masked), and the checks that a frame from a
## server must pass (not masked, no reserved bits, known opcodes, whole short control frames, the size cap, the order
## of fragments, UTF-8 in text, a valid close code). Everything here is a pure function on `Bytes`, `Int` and `String`,
## so the tests feed it bytes with no socket.
##
## A check that fails is a `Problem`: the close code to tell the server and a reason of at most 123 bytes.

import Binary from "std/binary"

# The opcodes of RFC 6455 5.2.
CONTINUATION = 0
TEXT = 1
BINARY = 2
CLOSE = 8
PING = 9
PONG = 10
## The most bytes of a control frame (RFC 6455 5.5).
CONTROL_BYTES = 125
## The most bytes of the reason of a close frame: a control frame holds 125, and the code takes 2.
REASON_BYTES = 123
## No status was sent: what a close frame with no payload means (never written on the wire).
CLOSE_NO_STATUS = 1005
CLOSE_NORMAL = 1000
CLOSE_PROTOCOL = 1002
## 1006 is never sent: it is what the program is told when the connection ended with no close frame.
CLOSE_ABNORMAL = 1006
## Data that is not valid for its type: a text message that is not UTF-8.
CLOSE_BAD_DATA = 1007
## A message over the size cap.
CLOSE_TOO_BIG = 1009

## A failed check: the close code to tell the server and why.
struct Problem
  code: Int
  reason: String
end

## The head of a frame. It is read in two steps: the first two bytes (`head_of`) and then the tail they announce
## (`tail_size`, `complete`). `length` holds the 7-bit length until the tail completes it, and is -1 for a 64-bit
## length that has its top bit set. `form` is the 7-bit length field as it came (126 and 127 announce a longer form).
## `key` is empty for a frame that is not masked.
struct Head
  fin: Bool
  opcode: Int
  masked: Bool
  reserved: Int
  length: Int
  form: Int
  key: Bytes
end

## The frames of a message that arrives in fragments: its kind, whether one is open, the pieces so far and their size.
struct Assembly
  text: Bool
  open: Bool
  parts: List[Bytes]
  total: Int
end

## What one data frame did to the message being assembled.
enum Taken
  More(Assembly)
  Whole(Bool, Bytes)
  Broken(Problem)
end

## What a close frame says: the server's code and reason, or a problem with the frame.
enum Closing
  Peer(Int, String)
  Invalid(Problem)
end

## A frame of a client: FIN set, the payload masked with the 4 bytes of `key`, which must be unpredictable (RFC 6455
## 5.3) and new for each frame.
def encode(opcode: Int, payload: Bytes, key: Bytes) -> Bytes
  size = payload.size
  first = Bytes.from_list([128 + opcode]).unwrap!
  length = NO_BYTES
  if size >= 65536
    length = Bytes.concat([Bytes.from_list([128 + 127]).unwrap!, Binary.write_i64_be(size)])
  elsif size >= 126
    length = Bytes.concat([Bytes.from_list([128 + 126]).unwrap!, Binary.write_u16_be(size).unwrap!])
  else
    length = Bytes.from_list([128 + size]).unwrap!
  end

  Bytes.concat([first, length, key, mask(payload, key)])
end

## The data with the mask taken on or off: each byte is xor-ed with the byte of the key at its place mod 4.
def mask(data: Bytes, key: Bytes) -> Bytes
  return data if key.empty? or data.empty?

  k = key.to_a
  out: List[Int] = []
  place = 0
  for byte in data
    out = out.push(Int.bit_xor(byte, k[place]))
    place = (place + 1) % KEY_BYTES
  end

  Bytes.from_list(out).unwrap!
end

## The first two bytes of a frame as a `Head` that has no tail yet.
def head_of(two: Bytes) -> Head
  first = two.at(0)
  second = two.at(1)
  Head(
    fin: first >= 128,
    opcode: first % 16,
    masked: second >= 128,
    reserved: (first / 16) % 8,
    length: second % 128,
    form: second % 128,
    key: NO_BYTES,
  )
end

## The bytes after the first two: the extended length (2 or 8 bytes) and the mask (4 bytes when the frame is masked).
def tail_size(head: Head) -> Int
  size = 0
  if head.length == 126
    size = 2
  elsif head.length == 127
    size = 8
  end

  return size + KEY_BYTES if head.masked

  size
end

## The head with its length and mask, from the tail that `tail_size` counted.
def complete(head: Head, tail: Bytes) -> Head
  length = head.length
  used = 0
  if head.length == 126
    length = Binary.read_u16_be(tail, 0).unwrap!
    used = 2
  elsif head.length == 127
    length = Binary.read_u64_be(tail, 0).unwrap_or(-1)
    used = 8
  end

  key = NO_BYTES
  if head.masked
    key = tail.slice(used, KEY_BYTES)
  end

  Head(
    fin: head.fin,
    opcode: head.opcode,
    masked: head.masked,
    reserved: head.reserved,
    length: length,
    form: head.form,
    key: key,
  )
end

## What is wrong with a head whose tail was read, when something is, given the `held` bytes of the earlier fragments
## of the message and the `max` size of a message. A server that breaks one of these rules is answered with the code
## of the problem.
def check_head(head: Head, max: Int, held: Int) -> Optional[Problem]
  return some(Problem(code: CLOSE_PROTOCOL, reason: "reserved bits are set")) if head.reserved != 0

  return some(Problem(code: CLOSE_PROTOCOL, reason: "a server frame must not be masked")) if head.masked

  return some(Problem(code: CLOSE_PROTOCOL, reason: "unknown opcode")) if not known_opcode?(head.opcode)

  return some(Problem(code: CLOSE_PROTOCOL, reason: "a length is not in its shortest form")) if long_form?(head)

  return check_control(head) if control?(head.opcode)

  return some(Problem(code: CLOSE_PROTOCOL, reason: "invalid frame length")) if head.length < 0

  # Not `held + length > max`: a length from the network can be 2^63 - 1, and the sum would overflow.
  return some(Problem(code: CLOSE_TOO_BIG, reason: "message too big")) if head.length > max - held

  none
end

## True for the opcodes of control frames (close, ping, pong).
def control?(opcode: Int) -> Bool = opcode >= CLOSE

## The state before the first frame of a message.
def new_assembly() -> Assembly = Assembly(text: false, open: false, parts: [], total: 0)

## Adds a data frame (text, binary or continuation) to the message being assembled. The message is whole at its last
## frame, and a text message must then be UTF-8. A fragment that starts a message while another is open, or that
## continues none, breaks the protocol; so does a message past `max` bytes in all.
def take(assembly: Assembly, head: Head, payload: Bytes, max: Int) -> Taken
  continuing = head.opcode == CONTINUATION
  if continuing and not assembly.open
    return Taken.Broken(Problem(code: CLOSE_PROTOCOL, reason: "a continuation with no message"))
  end

  if not continuing and assembly.open
    return Taken.Broken(Problem(code: CLOSE_PROTOCOL, reason: "a new message inside a fragmented one"))
  end

  text = assembly.text
  if not continuing
    text = head.opcode == TEXT
  end

  total = assembly.total + payload.size
  return Taken.Broken(Problem(code: CLOSE_TOO_BIG, reason: "message too big")) if total > max

  parts = assembly.parts.push(payload)
  return Taken.More(Assembly(text: text, open: true, parts: parts, total: total)) if not head.fin

  finished(text, Bytes.concat(parts))
end

## A close frame: no payload (no code), or a code of two bytes and a reason that is UTF-8. A code that no server may
## send (below 1000, 1004 to 1006, 1015 to 2999, past 4999) is a protocol error, as is one byte of payload.
def parse_close(payload: Bytes) -> Closing
  return Closing.Peer(CLOSE_NO_STATUS, "") if payload.empty?

  return Closing.Invalid(Problem(code: CLOSE_PROTOCOL, reason: "a close frame of one byte")) if payload.size == 1

  code = Binary.read_u16_be(payload, 0).unwrap!
  return Closing.Invalid(Problem(code: CLOSE_PROTOCOL, reason: "invalid close code #{code}")) if not valid_code?(code)

  case String.from_bytes(payload.drop(2))
    ok(reason) -> Closing.Peer(code, reason)
    error(_) -> Closing.Invalid(Problem(code: CLOSE_BAD_DATA, reason: "the close reason is not valid UTF-8"))
  end
end

## The payload of a close frame to send: the code and the reason. A code that no peer may send, or a reason over 123
## bytes, is an `error`.
def close_payload(code: Int, reason: String) -> Result[Bytes]
  return error("invalid close code #{code}") if not valid_code?(code)

  return error("the close reason is at most #{REASON_BYTES} bytes") if reason.bytes.size > REASON_BYTES

  ok(Bytes.concat([Binary.write_u16_be(code).unwrap!, reason.bytes]))
end

## True for a close code that a peer may send: 1000 to 1014 except 1004 to 1006, and 3000 to 4999.
def valid_code?(code: Int) -> Bool
  return true if code >= 3000 and code <= 4999

  code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006
end

private

KEY_BYTES = 4
NO_BYTES = Bytes.from_list([]).unwrap!

# RFC 6455 5.2: the shortest form of the length must be used (126 is for 126 to 65535, 127 for more).
def long_form?(head: Head) -> Bool
  return head.length < 126 if head.form == 126

  head.form == 127 and head.length >= 0 and head.length < 65_536
end

def known_opcode?(opcode: Int) -> Bool = opcode <= BINARY or (opcode >= CLOSE and opcode <= PONG)

# A control frame is whole and short. A length field of 126 or 127 says so before the tail is read.
def check_control(head: Head) -> Optional[Problem]
  return some(Problem(code: CLOSE_PROTOCOL, reason: "a control frame cannot be fragmented")) if not head.fin

  if head.length > CONTROL_BYTES or head.length < 0
    return some(Problem(code: CLOSE_PROTOCOL, reason: "a control frame is at most #{CONTROL_BYTES} bytes"))
  end

  none
end

def finished(text: Bool, data: Bytes) -> Taken
  if text and not String.from_bytes(data).ok?
    return Taken.Broken(Problem(code: CLOSE_BAD_DATA, reason: "text is not valid UTF-8"))
  end

  Taken.Whole(text, data)
end

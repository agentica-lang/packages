## The wire format of a connection (docs/protocol.md): a preamble, then frames. A frame is the length of what follows
## in 4 bytes, one byte for the kind, and the body, the Term CBOR of a struct that each kind has. Everything here is a
## pure function on `Bytes`: the length is checked before the body is read, and bytes from the network never halt it.

import Binary from "std/binary"
import Names from "names"
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
  return ok(Types.Message.Ignored(kind)) if IGNORABLE.include?(kind) and kind != KIND_GROUPS

  case kind
    _ if kind == KIND_HELLO -> hello(body)
    _ if kind == KIND_CHALLENGE -> challenge(body)
    _ if kind == KIND_PROOF -> proof(body)
    _ if kind == KIND_WELCOME -> empty(body, Types.Message.Welcome)
    _ if kind == KIND_PING -> empty(body, Types.Message.Ping)
    _ if kind == KIND_PONG -> empty(body, Types.Message.Pong)
    _ if kind == KIND_BYE -> bye(body)
    _ if kind == KIND_MAIL -> mail(body)
    _ if kind == KIND_GROUPS -> groups(body)
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
KIND_HELLO = 1
KIND_CHALLENGE = 2
KIND_PROOF = 3
KIND_WELCOME = 4
KIND_MAIL = 5
KIND_PING = 6
KIND_PONG = 7
KIND_BYE = 8
KIND_GROUPS = 64
IGNORABLE = 64..127

struct Empty
end

struct HelloBody
  node: String
  nonce: Bytes
end

struct ChallengeBody
  node: String
  nonce: Bytes
  proof: Bytes
end

struct ProofBody
  proof: Bytes
end

struct ByeBody
  reason: String
end

struct GroupsBody
  version: Int
  groups: List[Types.Membership]
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
    Types.Message.Hello(node, nonce) -> hello_payload(node, nonce)
    Types.Message.Challenge(node, nonce, proof) -> challenge_payload(node, nonce, proof)
    Types.Message.Proof(proof) -> proof_payload(proof)
    Types.Message.Welcome -> with_kind(KIND_WELCOME, Term.encode(Empty()))
    Types.Message.Ping -> with_kind(KIND_PING, Term.encode(Empty()))
    Types.Message.Pong -> with_kind(KIND_PONG, Term.encode(Empty()))
    Types.Message.Bye(reason) -> with_kind(KIND_BYE, Term.encode(ByeBody(reason: reason)))
    Types.Message.Mail(mailbox, body) -> mail_payload(mailbox, body)
    Types.Message.Groups(version, groups) -> groups_payload(version, groups)
    Types.Message.Ignored(_) -> protocol("a frame of an ignored kind is never written")
  end
end

def hello_payload(node: String, nonce: Bytes) -> Result[Bytes]
  try check_hello(node, nonce)
  with_kind(KIND_HELLO, Term.encode(HelloBody(node: node, nonce: nonce)))
end

def challenge_payload(node: String, nonce: Bytes, proof: Bytes) -> Result[Bytes]
  try check_hello(node, nonce)
  try check_proof(proof)
  with_kind(KIND_CHALLENGE, Term.encode(ChallengeBody(node: node, nonce: nonce, proof: proof)))
end

def proof_payload(proof: Bytes) -> Result[Bytes]
  try check_proof(proof)
  with_kind(KIND_PROOF, Term.encode(ProofBody(proof: proof)))
end

def check_hello(node: String, nonce: Bytes) -> Result[Void]
  return protocol("the node name or the nonce is not valid") if not Names.peer?(node, nonce)

  ok()
end

def check_proof(proof: Bytes) -> Result[Void]
  return protocol("a proof has #{Types.PROOF_BYTES} bytes") if proof.size != Types.PROOF_BYTES

  ok()
end

def mail_payload(mailbox: String, body: Bytes) -> Result[Bytes]
  try check_mailbox(mailbox)
  with_kind(KIND_MAIL, Term.encode(MailBody(mailbox: mailbox, body: body)))
end

def groups_payload(version: Int, groups: List[Types.Membership]) -> Result[Bytes]
  try check_groups(version, groups)
  with_kind(KIND_GROUPS, Term.encode(GroupsBody(version: version, groups: groups)))
end

def check_groups(version: Int, groups: List[Types.Membership]) -> Result[Void]
  return protocol("the version of groups is 1 or more") if version < 1

  seen: Map[String, Bool] = {}
  for entry in groups
    try check_mailbox(entry.group)
    try check_mailbox(entry.mailbox)
    key = "#{entry.group.bytes.size}:#{entry.group}#{entry.mailbox}"
    return protocol("a group has the same mailbox twice") if seen.has_key?(key)

    seen = seen.put(key, true)
  end

  ok()
end

def groups(body: Bytes) -> Result[Types.Message]
  case Term.decode(body, GroupsBody)
    ok(g) -> groups_of(g)
    error(e) -> protocol("a groups with a bad body: #{e.message}")
  end
end

def groups_of(g: GroupsBody) -> Result[Types.Message]
  try check_groups(g.version, g.groups)
  ok(Types.Message.Groups(g.version, g.groups))
end

def with_kind(kind: Int, body: Result[Bytes]) -> Result[Bytes]
  case body
    ok(encoded) -> ok(Bytes.from_list([kind]).unwrap! + encoded)
    error(e) -> protocol("cannot encode the body: #{e.message}")
  end
end

def check_mailbox(mailbox: String) -> Result[Void]
  return protocol("a mailbox name has 1 to #{Types.MAX_MAILBOX_BYTES} bytes") if not Names.mailbox_name?(mailbox)

  ok()
end

def empty(body: Bytes, message: Types.Message) -> Result[Types.Message]
  case Term.decode(body, Empty)
    ok(_) -> ok(message)
    error(e) -> protocol("a ping or a pong with a bad body: #{e.message}")
  end
end

def hello(body: Bytes) -> Result[Types.Message]
  case Term.decode(body, HelloBody)
    ok(h) -> hello_of(h)
    error(e) -> protocol("a hello with a bad body: #{e.message}")
  end
end

def hello_of(h: HelloBody) -> Result[Types.Message]
  try check_hello(h.node, h.nonce)
  ok(Types.Message.Hello(h.node, h.nonce))
end

def challenge(body: Bytes) -> Result[Types.Message]
  case Term.decode(body, ChallengeBody)
    ok(c) -> challenge_of(c)
    error(e) -> protocol("a challenge with a bad body: #{e.message}")
  end
end

def challenge_of(c: ChallengeBody) -> Result[Types.Message]
  try check_hello(c.node, c.nonce)
  try check_proof(c.proof)
  ok(Types.Message.Challenge(c.node, c.nonce, c.proof))
end

def proof(body: Bytes) -> Result[Types.Message]
  case Term.decode(body, ProofBody)
    ok(p) -> proof_of(p)
    error(e) -> protocol("a proof with a bad body: #{e.message}")
  end
end

def proof_of(p: ProofBody) -> Result[Types.Message]
  try check_proof(p.proof)
  ok(Types.Message.Proof(p.proof))
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

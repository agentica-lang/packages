## The message of RFC 1035 4: the query that a client writes and the answer that it reads. Everything here is a pure
## function on `Bytes`, so a test feeds it bytes with no socket.
##
## `decode` checks the message against its own size before it trusts a number in it: the counts of the header must fit
## the bytes that follow, a length must end inside the message, a name may only point back (`Name.decode`), and the
## data of an A or AAAA record must be 4 or 16 bytes. It gives an `error` of the kind `dns.malformed` when a check
## fails, and never halts on bytes from the network.

import Binary from "std/binary"
import Name from "name"
import Types from "types"

## The bytes of a query for one question: the header (the id, the flag that asks the server to recurse, one question)
## and the question. No EDNS record is added, so the answer is the plain one of RFC 1035.
def encode_query(id: Int, name: String, type: Int, recursion_desired: Bool = true) -> Result[Bytes]
  return malformed("the id must be from 0 to 65535") if id < 0 or id > MAX_U16
  return malformed("the type must be from 1 to 65535") if type < 1 or type > MAX_U16
  encoded = try Name.encode(name)
  flags = 0
  if recursion_desired
    flags = RD_BIT
  end

  parts = [
    try Binary.write_u16_be(id),
    try Binary.write_u16_be(flags),
    try Binary.write_u16_be(1),
    try Binary.write_u16_be(0),
    try Binary.write_u16_be(0),
    try Binary.write_u16_be(0),
    encoded,
    try Binary.write_u16_be(type),
    try Binary.write_u16_be(Types.CLASS_IN),
  ]

  ok(Bytes.concat(parts))
end

## Reads a message, an answer or a query. A name keeps the case that it came with. The bytes after the last record are
## ignored.
def decode(data: Bytes) -> Result[Types.Message]
  return malformed("a message has at least #{HEADER_BYTES} bytes") if data.size < HEADER_BYTES
  return malformed("a message has at most #{Types.MAX_MESSAGE_BYTES} bytes") if data.size > Types.MAX_MESSAGE_BYTES
  flags = try Binary.read_u16_be(data, 2)
  questions_count = try Binary.read_u16_be(data, 4)
  answers_count = try Binary.read_u16_be(data, 6)
  authorities_count = try Binary.read_u16_be(data, 8)
  additionals_count = try Binary.read_u16_be(data, 10)
  records_count = answers_count + authorities_count + additionals_count
  # Each question takes at least 5 bytes and each record 11: a count that the bytes cannot hold is a lie, and the loops
  # below never run longer than the data.
  if questions_count * MIN_QUESTION_BYTES + records_count * MIN_RECORD_BYTES > data.size - HEADER_BYTES
    return malformed("the counts of the message do not fit its size")
  end

  asked = try read_questions(data, HEADER_BYTES, questions_count)
  answers = try read_records(data, asked.next, answers_count)
  authorities = try read_records(data, answers.next, authorities_count)
  additionals = try read_records(data, authorities.next, additionals_count)
  ok(
    Types.Message(
      id: try Binary.read_u16_be(data, 0),
      response: bit?(flags, QR_BIT),
      opcode: flags.shift_right(11).bit_and(15),
      authoritative: bit?(flags, AA_BIT),
      truncated: bit?(flags, TC_BIT),
      recursion_desired: bit?(flags, RD_BIT),
      recursion_available: bit?(flags, RA_BIT),
      rcode: flags.bit_and(15),
      questions: asked.items,
      answers: answers.items,
      authorities: authorities.items,
      additionals: additionals.items,
    ),
  )
end

private

HEADER_BYTES = 12
MAX_U16 = 65_535
MIN_QUESTION_BYTES = 5
MIN_RECORD_BYTES = 11
# The bits of the flag word (RFC 1035 4.1.1).
QR_BIT = 32_768
AA_BIT = 1_024
TC_BIT = 512
RD_BIT = 256
RA_BIT = 128
# A TTL with this bit set counts as 0 (RFC 2181 8).
TTL_TOP_BIT = 2_147_483_648
IPV4_BYTES = 4
IPV6_BYTES = 16
IPV6_GROUPS = 8

struct Questions
  items: List[Types.Question]
  next: Int
end

struct Records
  items: List[Types.Record]
  next: Int
end

struct One
  record: Types.Record
  next: Int
end

def malformed[T](message: String) -> Result[T] = error("dns: #{message}", kind: Types.MALFORMED)

def bit?(flags: Int, bit: Int) -> Bool = flags.bit_and(bit) != 0

def read_questions(data: Bytes, offset: Int, count: Int) -> Result[Questions]
  items: List[Types.Question] = []
  position = offset
  for _ in 0...count
    name = try Name.decode(data, position)
    return malformed("a question runs past the end of the message") if name.next + 4 > data.size
    items = items.push(
      Types.Question(
        name: name.name,
        type: try Binary.read_u16_be(data, name.next),
        class: try Binary.read_u16_be(data, name.next + 2),
      ),
    )

    position = name.next + 4
  end

  ok(Questions(items: items, next: position))
end

def read_records(data: Bytes, offset: Int, count: Int) -> Result[Records]
  items: List[Types.Record] = []
  position = offset
  for _ in 0...count
    one = try read_record(data, position)
    items = items.push(one.record)
    position = one.next
  end

  ok(Records(items: items, next: position))
end

def read_record(data: Bytes, offset: Int) -> Result[One]
  name = try Name.decode(data, offset)
  fixed = name.next
  return malformed("a record runs past the end of the message") if fixed + 10 > data.size
  type = try Binary.read_u16_be(data, fixed)
  length = try Binary.read_u16_be(data, fixed + 8)
  start = fixed + 10
  return malformed("the data of a record runs past the end of the message") if length > data.size - start
  ttl = try Binary.read_u32_be(data, fixed + 4)
  if ttl >= TTL_TOP_BIT
    ttl = 0
  end

  record = Types.Record(
    name: name.name,
    type: type,
    class: try Binary.read_u16_be(data, fixed + 2),
    ttl: ttl,
    data: try read_data(data, type, start, start + length),
  )

  ok(One(record: record, next: start + length))
end

# The data of a record between `start` and `stop`. A name inside it may point anywhere before it, and must end where
# the data ends.
def read_data(data: Bytes, type: Int, start: Int, stop: Int) -> Result[Types.Data]
  if type == Types.TYPE_A
    return malformed("the data of an A record must be #{IPV4_BYTES} bytes") if stop - start != IPV4_BYTES
    return ok(Types.Data.A(ipv4(data.slice(start, IPV4_BYTES))))
  elsif type == Types.TYPE_AAAA
    return malformed("the data of an AAAA record must be #{IPV6_BYTES} bytes") if stop - start != IPV6_BYTES
    return ok(Types.Data.Aaaa(ipv6(data.slice(start, IPV6_BYTES))))
  elsif type == Types.TYPE_CNAME
    return ok(Types.Data.Cname(try name_data(data, start, stop)))
  elsif type == Types.TYPE_NS
    return ok(Types.Data.Ns(try name_data(data, start, stop)))
  elsif type == Types.TYPE_PTR
    return ok(Types.Data.Ptr(try name_data(data, start, stop)))
  end

  ok(Types.Data.Other(data.slice(start, stop - start)))
end

def name_data(data: Bytes, start: Int, stop: Int) -> Result[String]
  name = try Name.decode(data, start)
  return malformed("a name in the data of a record ends outside the data") if name.next != stop
  ok(name.name)
end

def ipv4(bytes: Bytes) -> String
  parts = bytes.to_a.map { |b| b.to_s }
  parts.join(".")
end

# The text of RFC 5952: lower case, no leading zeros, and the first of the longest runs of two or more zero groups
# written as `::`.
def ipv6(bytes: Bytes) -> String
  groups: List[Int] = []
  for index in 0...IPV6_GROUPS
    groups = groups.push(bytes[index * 2] * 256 + bytes[index * 2 + 1])
  end

  run_start = -1
  run_size = 0
  index = 0
  while index < IPV6_GROUPS
    size = 0
    while index + size < IPV6_GROUPS and groups[index + size] == 0
      size += 1
    end

    if size > run_size
      run_start = index
      run_size = size
    end

    index += size + 1
  end

  return hex_groups(groups) if run_size < 2
  before = hex_groups(groups.take(run_start))
  after = hex_groups(groups.drop(run_start + run_size))
  "#{before}::#{after}"
end

def hex_groups(groups: List[Int]) -> String
  parts = groups.map { |group| hex(group) }
  parts.join(":")
end

def hex(group: Int) -> String
  text = OpenSSL.Digest.hexencode(Bytes.from_list([group / 256, group % 256]).unwrap!)
  while text.length > 1 and text.start_with?("0")
    text = text.slice(1, text.length - 1)
  end

  text
end

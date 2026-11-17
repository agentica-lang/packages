## The records of the package: the message of RFC 1035 as a decoder reads it.

## The types of record that the package asks for or decodes.
TYPE_A = 1
TYPE_NS = 2
TYPE_CNAME = 5
TYPE_PTR = 12
TYPE_AAAA = 28
TYPE_OPT = 41

## The class of the Internet, the only one in use.
CLASS_IN = 1

## The codes of the answer (RFC 1035 4.1.1) that the package names. Others are kept as numbers.
RCODE_NOERROR = 0
RCODE_FORMERR = 1
RCODE_SERVFAIL = 2
RCODE_NXDOMAIN = 3
RCODE_NOTIMP = 4
RCODE_REFUSED = 5

## The most bytes of a message: the 16-bit length of a TCP frame (RFC 7766).
MAX_MESSAGE_BYTES = 65_535

## The kinds of the errors of the package, for `e.is_a?("dns.malformed")`: a message that breaks RFC 1035.
MALFORMED = "dns.malformed"

## What a record holds. A, AAAA, CNAME, NS and PTR are decoded: an address as text, a name as text. Any other type
## keeps its `rdata` as it came.
enum Data
  A(String)
  Aaaa(String)
  Cname(String)
  Ns(String)
  Ptr(String)
  Other(Bytes)
end

## A question: a name, a type and a class. A name is text without the final dot ("" is the root); a dot inside a label is
## written `\.`, a backslash `\\`, and a byte that is not printable ASCII `\DDD` with its decimal value.
struct Question
  name: String
  type: Int
  class: Int
end

## One record of an answer. `ttl` is in seconds; a value with the top bit set counts as 0 (RFC 2181 8), except in an
## OPT record (type 41), where it holds flags and is kept as it came.
struct Record
  name: String
  type: Int
  class: Int
  ttl: Int
  data: Data
end

## A message, as `decode` reads it. `rcode` is the 4-bit code of the answer.
struct Message
  id: Int
  response: Bool
  opcode: Int
  authoritative: Bool
  truncated: Bool
  recursion_desired: Bool
  recursion_available: Bool
  rcode: Int
  questions: List[Question]
  answers: List[Record]
  authorities: List[Record]
  additionals: List[Record]
end

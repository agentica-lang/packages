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

## The kinds of the errors of the package, for `e.is_a?("dns.nxdomain")`. A message that breaks RFC 1035.
MALFORMED = "dns.malformed"

## The name does not exist (NXDOMAIN): the one answer that ends the search, since the next nameserver would say the
## same.
NXDOMAIN = "dns.nxdomain"

## The nameserver failed (SERVFAIL), or answered with a code that has no kind of its own.
SERVFAIL = "dns.servfail"

## The nameserver refused the query (REFUSED).
REFUSED = "dns.refused"

## The answer is cut (the TC flag): a TCP, TLS or HTTPS answer is never meant to be, so the server is not one to trust.
TRUNCATED = "dns.truncated"

## No answer in time, or the connection broke.
TIMEOUT = "dns.timeout"
NETWORK = "dns.network"

## An answer that is not for the query: another id, no QR flag or another question.
MISMATCH = "dns.mismatch"

## More CNAMEs than `Options.max_cnames`, or a loop of them.
CNAME_LIMIT = "dns.cname_limit"

## The name exists but has no address of the kind asked.
NO_ADDRESS = "dns.no_address"

## The most that a timeout may be, in milliseconds: one day.
MAX_TIMEOUT_MS = 86_400_000

## A nameserver. `Tcp` is DNS over TCP (RFC 7766): the host (a name or an address) and the port, 53 for most. `Tls` is
## DNS over TLS (RFC 7858): the host, the port (853 for most) and the name that the certificate must have, "" for the
## host.
enum Server
  Tcp(String, Int)
  Tls(String, Int, String)
end

## What a resolver takes. `timeout_ms` is how long each nameserver has for the whole exchange (connect, send and read),
## from 1 to `MAX_TIMEOUT_MS`. `max_cnames` is how many CNAMEs a name may follow, from 0 to 32. `tls` is the client
## context of the `Tls` servers (the system trust by default).
struct Options
  timeout_ms: Int = 3_000
  max_cnames: Int = 8
  tls: Optional[TLS.Context] = none
end

## The nameservers to ask, in order, and the options. Make one with `resolver`.
struct Resolver
  servers: List[Server]
  options: Options
  context: Optional[TLS.Context]
end

## An address of an answer: its text, `TYPE_A` or `TYPE_AAAA`, and its TTL in seconds (the smallest of the chain of
## CNAMEs that led to it).
struct Address
  address: String
  type: Int
  ttl: Int
end

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

## A question: a name, a type and a class. A name is text without the final dot ("" is the root); a dot inside a label
## is written `\.`, a backslash `\\`, and a byte that is not printable ASCII `\DDD` with its decimal value.
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

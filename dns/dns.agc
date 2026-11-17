## A DNS client over TCP, TLS and HTTPS (RFC 1035, 7766, 7858 and 8484). This first part is the codec of the messages:
## `encode_query` writes the query for one question and `decode` reads an answer, both pure functions on `Bytes`.
##
## ```ruby
## import DNS from "pkg/dns/dns"
##
## query = DNS.encode_query(4242, "example.com", DNS.TYPE_A).unwrap!
## message = DNS.decode(query).unwrap!
## puts(message.questions[0].name)
## ```

import Wire from "src/wire"
import Types from "src/types"

export Types.TYPE_A
export Types.TYPE_NS
export Types.TYPE_CNAME
export Types.TYPE_PTR
export Types.TYPE_AAAA
export Types.TYPE_OPT
export Types.CLASS_IN
export Types.RCODE_NOERROR
export Types.RCODE_FORMERR
export Types.RCODE_SERVFAIL
export Types.RCODE_NXDOMAIN
export Types.RCODE_NOTIMP
export Types.RCODE_REFUSED
export Types.MALFORMED
export Types.Data
export Types.Question
export Types.Record
export Types.Message

## The bytes of a query for one question of the class IN, with the flag that asks the server to recurse unless
## `recursion_desired` is false. `name` is text without the final dot (`\.` writes a dot inside a label, `\DDD` a byte).
## An `error` of the kind `dns.malformed` for an id or type outside 16 bits, an empty label, a label over 63 bytes and a
## name over 255.
def encode_query(id: Int, name: String, type: Int, recursion_desired: Bool = true) -> Result[Bytes]
  Wire.encode_query(id, name, type, recursion_desired)
end

## Reads a message. An `error` of the kind `dns.malformed` for bytes that break RFC 1035: a message under 12 or over
## 65535 bytes, counts that the bytes cannot hold, a name or a length that runs past the end, a compression pointer that
## does not go back, a label of a reserved type, and an A or AAAA record whose data is not 4 or 16 bytes. A, AAAA, CNAME,
## NS and PTR records are decoded; the data of any other type is `Data.Other` with the bytes as they came.
def decode(data: Bytes) -> Result[Types.Message] = Wire.decode(data)

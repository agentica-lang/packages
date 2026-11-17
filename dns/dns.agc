## A DNS client over TCP and TLS (RFC 1035, 7766 and 7858): it asks the nameservers that you choose, in order, and reads
## the answers with a codec of its own. There is no UDP in `std`, so a query goes over a stream, with the length in
## front.
##
## ```ruby
## import DNS from "pkg/dns/dns"
##
## servers = [DNS.Server.Tcp("9.9.9.9", 53), DNS.Server.Tls("1.1.1.1", 853, "one.one.one.one")]
## resolver = DNS.resolver(servers, DNS.Options(timeout_ms: 2000)).unwrap!
## puts(DNS.lookup(resolver, "example.com").unwrap!)
## ```
##
## The codec is in `encode_query` and `decode`, pure functions on `Bytes`.

import Client from "src/client"
import Name from "src/name"
import Types from "src/types"
import Wire from "src/wire"

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
export Types.NXDOMAIN
export Types.SERVFAIL
export Types.REFUSED
export Types.TRUNCATED
export Types.TIMEOUT
export Types.NETWORK
export Types.MISMATCH
export Types.CNAME_LIMIT
export Types.NO_ADDRESS
export Types.MAX_TIMEOUT_MS
export Types.Data
export Types.Question
export Types.Record
export Types.Message
export Types.Server
export Types.Options
export Types.Resolver
export Types.Address

## Makes a resolver of the nameservers, asked in order. An `error` of the kind `dns.malformed` for no server, more than
## 16, a server with no host or a port outside 1 to 65535, a timeout outside 1 to `MAX_TIMEOUT_MS` and `max_cnames`
## outside 0 to 32.
def resolver(servers: List[Types.Server], options: Types.Options = Types.Options()) -> Result[Types.Resolver]
  Client.resolver(servers, options)
end

## The addresses of a host as text, the IPv4 ones first and then the IPv6 ones, with the CNAMEs followed: the shape of
## the `resolver:` of http-client. An `error` of the kind `dns.no_address` for a host that exists and has none; the other
## kinds are those of `query`.
def lookup(resolver: Types.Resolver, host: String) -> Result[List[String]] = Client.lookup(resolver, host)

## `lookup` of a resolver as a function, for an option that takes one.
def lookuper(resolver: Types.Resolver) -> Fn[String, Result[List[String]]] = ->(host) { Client.lookup(resolver, host) }

## The addresses of a name of one type, `TYPE_A` or `TYPE_AAAA`, each with its TTL, with the CNAMEs followed (at most
## `max_cnames`: `dns.cname_limit` past that or in a loop). An empty list for a name that has none of that type.
def addresses(resolver: Types.Resolver, name: String, type: Int) -> Result[List[Types.Address]]
  Client.addresses(resolver, name, type)
end

## Asks the nameservers in order and returns the first answer that is good: a response to this query (the id, the
## question and the QR flag are checked) that is not cut and has the code NOERROR. NXDOMAIN ends the search with an
## `error` of the kind `dns.nxdomain`; a timeout (`dns.timeout`), a broken connection (`dns.network`), SERVFAIL
## (`dns.servfail`), REFUSED (`dns.refused`), a cut answer (`dns.truncated`) and a bad one (`dns.mismatch`,
## `dns.malformed`) go on to the next nameserver, and the `error` of the last one is the result when all fail. The
## message is what the server said, with no CNAME followed.
def query(resolver: Types.Resolver, name: String, type: Int) -> Result[Types.Message]
  Client.query(resolver, name, type)
end

## Returns true when two names are the same for DNS: `example.com.` and `EXAMPLE.com` are.
def same_name?(a: String, b: String) -> Bool = Name.same?(a, b)

## The bytes of a query for one question of the class IN, with the flag that asks the server to recurse unless
## `recursion_desired` is false. `name` is text without the final dot (`\.` writes a dot inside a label, `\DDD` a byte).
## An `error` of the kind `dns.malformed` for an id or type outside 16 bits, an empty label, a label over 63 bytes and a
## name over 255.
def encode_query(id: Int, name: String, type: Int, recursion_desired: Bool = true) -> Result[Bytes]
  Wire.encode_query(id, name, type, recursion_desired)
end

## Reads a message. An `error` of the kind `dns.malformed` for bytes that break RFC 1035: a message under 12 or over
## 65535 bytes, counts that the bytes cannot hold, a name or a length that runs past the end, a compression pointer that
## does not go before its name, a label of a reserved type, and an A or AAAA record whose data is not 4 or 16 bytes. A,
## AAAA, CNAME, NS and PTR records are decoded; the data of any other type is `Data.Other` with the bytes as they came.
def decode(data: Bytes) -> Result[Types.Message] = Wire.decode(data)

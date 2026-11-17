---
title: dns
description: A DNS client in Agentica that asks the nameservers you choose over TCP and TLS, follows CNAMEs, and reads answers with a bounded codec of RFC 1035.
---

`dns` is a DNS client written in Agentica, for programs that must ask a nameserver they choose. It sends each query over TCP (RFC 7766) or over TLS (RFC 7858, DoT), because `std` has no UDP. It tries the nameservers in order, checks every answer against its query, follows CNAMEs, and gives the addresses with their TTLs. The codec of RFC 1035 under it is also public: pure functions on `Bytes`.

## Install

Needs Agentica 0.33.1 or later. Add it in a project with an `agentica.toml`:

```sh
agentica add dns https://github.com/agentica-lang/packages --tag dns-0.1.0 --subdir dns
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
dns = { git = "https://github.com/agentica-lang/packages", tag = "dns-0.1.0", subdir = "dns" }
```

## Example

A resolver of two nameservers, one over TCP and one over TLS (DoT) with the name that its certificate must have:

```agentica {mode="check"}
import DNS from "pkg/dns/dns"

def main() -> Void
  servers = [DNS.Server.Tcp("9.9.9.9", 53), DNS.Server.Tls("1.1.1.1", 853, "one.one.one.one")]
  resolver = DNS.resolver(servers, DNS.Options(timeout_ms: 2000)).unwrap!
  for address in DNS.addresses(resolver, "example.com", DNS.TYPE_A).unwrap!
    puts("#{address.address} for #{address.ttl} seconds")
  end

  puts(DNS.lookup(resolver, "example.com").unwrap!)
end
```

`DNS.lookup` gives the addresses as text, IPv4 first, and `DNS.lookuper(resolver)` is the same as a function, the shape of the `resolver:` option of http-client.

## Nameservers

`DNS.Server.Tcp(host, port)` is DNS over TCP, and `DNS.Server.Tls(host, port, name)` is DNS over TLS: `name` is what the certificate must have, `""` for the host. A resolver has 1 to 16 servers and asks them in order, each with `timeout_ms` for the whole exchange (connect, send and read). `Options.tls` is the client context for the TLS servers, the system trust by default.

A query that fails goes on to the next server: a timeout, a broken connection, SERVFAIL, REFUSED, a cut answer, an answer that is not for the query. When all fail, the error of the last one is the result. NXDOMAIN ends the search, since the next server would say the same.

Every answer is checked: its id is the one of the query, it has the QR flag, and its question is the one asked (the names compare without case).

## Errors

An `error` has a kind, tested with `e.is_a?("dns.nxdomain")`:

| Kind | When |
|---|---|
| `dns.nxdomain` | the name does not exist |
| `dns.servfail` | SERVFAIL, or any other code of the server |
| `dns.refused` | the server refused the query |
| `dns.truncated` | the answer has the TC flag |
| `dns.timeout` | no answer in time |
| `dns.network` | the connection or the TLS handshake failed, or ended before the whole answer |
| `dns.mismatch` | the answer is not for the query |
| `dns.malformed` | bytes that break RFC 1035, or an argument that does not fit |
| `dns.cname_limit` | more CNAMEs than `max_cnames` (8 by default), or a loop |
| `dns.no_address` | `lookup` of a name that has no address |

## The codec

`DNS.encode_query` writes a query and `DNS.decode` reads any message, here the query itself:

```agentica
import DNS from "pkg/dns/dns"

def main() -> Void
  query = DNS.encode_query(4242, "example.com", DNS.TYPE_A).unwrap!
  puts(OpenSSL.Digest.hexencode(query))
  message = DNS.decode(query).unwrap!
  puts("#{message.questions[0].name} type #{message.questions[0].type}")
end
```

```output
109201000001000000000000076578616d706c6503636f6d0000010001
example.com type 1
```

## Names

A name is text with no final dot, and `""` is the root. A dot inside a label is written `\.`, a backslash `\\`, and a byte that is not printable ASCII `\DDD` with its decimal value, so each name has one text. A label has 63 bytes at most and a name 255.

## Reading a message

`DNS.decode` returns a `DNS.Message`: the id, the flags, the code of the answer (`rcode`) and the four sections (`questions`, `answers`, `authorities`, `additionals`). A record has a name, a type, a class, a TTL in seconds and its data: `Data.A` and `Data.Aaaa` with the address as text, `Data.Cname`, `Data.Ns` and `Data.Ptr` with a name, and `Data.Other` with the bytes of any other type.

`decode` never halts on bytes from the network. It gives an `error` of the kind `dns.malformed` for a message that breaks RFC 1035:

- a message under 12 bytes or over 65535;
- counts that the bytes cannot hold, or a length that ends past the message;
- a compression pointer that goes into the header or does not go before the name that holds it (so a name never reads a byte twice and a loop cannot happen), more than 32 pointers in a name, and a label of a reserved type;
- an A record that is not 4 bytes, an AAAA that is not 16, and a name inside the data of a record that does not fill it.

A name is read once for each place where it starts, so a message with thousands of records that point at one long name costs little.

A TTL with the top bit set counts as 0 (RFC 2181), except in an OPT record (type 41), where it holds flags.

An IPv6 address is written as RFC 5952 says, and an IPv4-mapped one as `::ffff:1.2.3.4`.

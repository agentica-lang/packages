---
title: Codec
description: The codec of RFC 1035 of the dns package, which writes a query and reads any message, with limits on every size.
weight: 4
---

## Nameservers

`DNS.Server.Tcp(host, port)` is DNS over TCP, and `DNS.Server.Tls(host, port, name)` is DNS over TLS: `name` is what the certificate must have, `""` for the host. `DNS.Server.Https(url)` is DNS over HTTPS: the `https://` URL of the server, to which each query goes as a POST of the type `application/dns-message` with the id 0 (RFC 8484); an answer must be a 200 of that type. A resolver has 1 to 16 servers and asks them in order, each with `timeout_ms` for the whole exchange (connect, send and read). `Options.tls` is the client context for the TLS and HTTPS servers, the system trust by default; the system trust is loaded only when a `Tls` server needs it.

A query that fails goes on to the next server: a timeout, a broken connection, SERVFAIL, REFUSED, a cut answer, an answer that is not for the query. When all fail, the error of the last one is the result. NXDOMAIN ends the search, since the next server would say the same.

Every answer is checked: its id is the one of the query, it has the QR flag, and its question is the one asked (the names compare without case, as `DNS.same_name?(a, b)` does: `example.com.` is `EXAMPLE.com`).

## The nameservers of the system

Nothing reads `/etc/resolv.conf` unless you ask. `DNS.system_servers()` gives its `nameserver` lines (at most 3, as the C library reads them) as `Tcp` servers on port 53, and `DNS.system_servers(path)` reads another file. Not every system resolver answers over TCP, so use it only when yours does.

```agentica {mode="check"}
import DNS from "pkg/dns/dns"

def main() -> Void
  servers = DNS.system_servers().unwrap!
  resolver = DNS.resolver(servers).unwrap!
  puts(DNS.lookup(resolver, "example.com").unwrap!)
end
```

## Time

Each nameserver has `timeout_ms` for a query. A query takes at most that for each server, `lookup` asks A and then AAAA (and skips AAAA when the name does not exist), and each CNAME that leaves an answer adds a query, so a `lookup` takes at most `2 * (max_cnames + 1) * servers * timeout_ms`.

## Errors

An `error` has a kind, tested with `e.is_a?("dns.nxdomain")`:

| Kind | When |
|---|---|
| `dns.nxdomain` | the name does not exist |
| `dns.servfail` | SERVFAIL, or any other code of the server |
| `dns.refused` | the server refused the query |
| `dns.truncated` | the answer has the TC flag |
| `dns.timeout` | no answer in time |
| `dns.network` | the connection or the TLS handshake failed, ended before the whole answer, or an HTTPS server did not answer 200 |
| `dns.mismatch` | the answer is not for the query |
| `dns.malformed` | bytes that break RFC 1035, an HTTPS answer of another type, or an argument that does not fit |
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

`DNS.decode` reads an answer the same way. This one has an A record and a CNAME, whose names are pointers to the question (RFC 1035 4.1.4):

```agentica
import DNS from "pkg/dns/dns"

def main() -> Void
  hex = "abcd81800001000200000000076578616d706c6503636f6d0000010001"
  hex = hex + "c00c000100010000012c00047f000001" + "c00c000500010000003c0002c00c"
  message = DNS.decode(OpenSSL.Digest.hexdecode(hex).unwrap!).unwrap!
  puts("id #{message.id}, #{message.answers.length} answers, code #{message.rcode}")
  for record in message.answers
    puts("#{record.name} #{record.ttl} #{record.data}")
  end
end
```

```output
id 43981, 2 answers, code 0
example.com 300 Data.A("127.0.0.1")
example.com 60 Data.Cname("example.com")
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

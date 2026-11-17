---
title: dns
description: A DNS client in Agentica. This first part is the codec of RFC 1035, which writes a query and reads an answer with compressed names, with limits on every size.
---

`dns` is a DNS client written in Agentica, for programs that must ask a nameserver they choose. The transports (TCP, TLS and HTTPS) come in the next releases. This one has the codec: pure functions on `Bytes`, so it works with any transport.

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

---
title: Codec
description: The codec of RFC 1035 of the dns package, which writes a query and reads any message, with limits on every size.
weight: 4
---

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

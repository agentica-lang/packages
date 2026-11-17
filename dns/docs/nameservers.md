---
title: Nameservers
description: The transports of the dns package (TCP, TLS and HTTPS), the order of the servers, the timeouts, the checks of an answer, and the nameservers of the system.
weight: 2
---

## Servers

A resolver has 1 to 16 servers, asked in order:

- `DNS.Server.Tcp(host, port)` is DNS over TCP (RFC 7766): the message with its 2-byte length in front, on a connection of its own.
- `DNS.Server.Tls(host, port, name)` is DNS over TLS (RFC 7858): the same over TLS. The connection goes to `host`, and the certificate must have `name`, or `host` when `name` is `""`. So `Tls("1.1.1.1", 853, "one.one.one.one")` connects to the address and checks the name.
- `DNS.Server.Https(url)` is DNS over HTTPS (RFC 8484): the `https://` URL of the server. Each query is a POST of the type `application/dns-message` with the id 0, and an answer must be a 200 of that type, at most 65535 bytes. A `http://` URL is an error when the resolver is made.

`DNS.Options` has three fields:

- `timeout_ms` (3000 by default, 1 to one day): how long each server has for a whole query. For TCP and TLS it covers the connect, the handshake, the send and the read; for HTTPS, the whole request.
- `max_cnames` (8, 0 to 32): how many CNAMEs a name may follow.
- `tls`: the client context of the TLS and HTTPS servers, the system trust by default. Pass `TLS.client_context(TLS.ClientOptions(ca_file: "ca.pem"))` to trust your own CA.

DoH goes through `std/http` with no proxy and no connection reuse: each query makes its own TLS handshake, so a `lookup` (an A and an AAAA query) makes two. TCP and TLS keep nothing between queries either.

## Order and failures

A query goes to the first server. When it fails, the next one gets it: a timeout, a broken connection, SERVFAIL, REFUSED, a cut answer, and an answer that is not for the query. When all fail, the `error` of the last one is the result. NXDOMAIN ends the search, since the next server would say the same, and an NXDOMAIN answer must have its question.

## What is checked in an answer

Every answer must have the id of the query (0 over HTTPS), the QR flag, and one question that is the one asked, with the same type and class and the same name (names compare without case, as `DNS.same_name?(a, b)` does: `example.com.` is `EXAMPLE.com`). A server that fails may leave out the question. An answer with the TC flag is an error: a stream answer is never meant to be cut.

`DNS.addresses` takes only records of the class IN whose owner is the name asked or a name of its CNAME chain, so a record that a server adds for another name is not an address. The TTL of an address is the smallest of its chain.

## CNAMEs

A CNAME in the answer is followed. When the chain leaves the answer, the end of it is asked in a new query. More than `max_cnames` links, or a loop, is an error of the kind `dns.cname_limit`. A name that exists with no address of the type gives an empty list from `addresses`, and `dns.no_address` from `lookup`.

## Time

Each nameserver has `timeout_ms` for a query, so a query takes at most that for each server; `lookup` asks A and then AAAA (and skips AAAA when the name does not exist), and each CNAME that leaves an answer adds a query, so a `lookup` takes at most `2 * (max_cnames + 1) * servers * timeout_ms`.

## The nameservers of the system

Nothing reads `/etc/resolv.conf` unless you ask. `DNS.system_servers()` gives its `nameserver` lines (at most 3, as the C library reads them) as `Tcp` servers on port 53, and `DNS.system_servers(path)` reads another file. A nameserver must be an IPv4 or IPv6 address: a name, an address with a zone (`fe80::1%eth0`) and a line that is not `nameserver` are skipped. `search`, `ndots` and `options` are not applied, so a host is always asked as written. Not every system resolver answers over TCP, so use it only when yours does.

```agentica {mode="check"}
import DNS from "pkg/dns/dns"

def main() -> Void
  servers = DNS.system_servers().unwrap!
  resolver = DNS.resolver(servers).unwrap!
  puts(DNS.lookup(resolver, "example.com").unwrap!)
end
```


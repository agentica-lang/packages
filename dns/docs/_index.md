---
title: dns
description: A DNS client in Agentica that asks the nameservers you choose over TCP, TLS and HTTPS, follows CNAMEs, and reads answers with a bounded codec of RFC 1035.
---

`dns` is a DNS client written in Agentica, for programs that must ask a nameserver they choose: a resolver of your own, a private network, a test, or a check that a name answers the same everywhere. `std` has no UDP, so each query goes over TCP (RFC 7766), over TLS (RFC 7858, DoT) or over HTTPS (RFC 8484, DoH).

It tries the nameservers in order, each with its own timeout. It checks every answer against its query (the id, the question), follows CNAMEs up to a limit, and gives the addresses with their TTLs. A failure has a kind of its own: the name does not exist, the server failed or refused, the answer was cut, nobody answered. The codec of RFC 1035 under it is public too: pure functions on `Bytes`, bounded on every size, that never halt on bytes from the network.

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

A resolver of three nameservers, over TCP, over TLS (DoT) with the name that its certificate must have, and over HTTPS (DoH):

```agentica {mode="check"}
import DNS from "pkg/dns/dns"

def main() -> Void
  servers = [
    DNS.Server.Tcp("9.9.9.9", 53),
    DNS.Server.Tls("1.1.1.1", 853, "one.one.one.one"),
    DNS.Server.Https("https://dns.google/dns-query"),
  ]
  resolver = DNS.resolver(servers, DNS.Options(timeout_ms: 2000)).unwrap!
  for address in DNS.addresses(resolver, "example.com", DNS.TYPE_A).unwrap!
    puts("#{address.address} for #{address.ttl} seconds")
  end

  puts(DNS.lookup(resolver, "example.com").unwrap!)
end
```

`DNS.addresses` gives the records of one type with their TTLs. `DNS.lookup` gives the addresses of both kinds as text, IPv4 first, and `DNS.lookuper(resolver)` is the same as a function: the shape of the `resolver:` option of http-client.

## The functions

| Function | What it does |
|---|---|
| `DNS.resolver(servers, options)` | checks the nameservers and the options, and makes a resolver |
| `DNS.lookup(resolver, host)` | the addresses of a host as text, IPv4 first |
| `DNS.lookuper(resolver)` | `lookup` as a function of a host |
| `DNS.addresses(resolver, name, type)` | the A or AAAA records of a name, with their TTLs, the CNAMEs followed |
| `DNS.query(resolver, name, type)` | the first good answer, as the server said it |
| `DNS.system_servers(path)` | the nameservers of a `resolv.conf`, only when you ask |
| `DNS.parse_resolv_conf(text)` | the same for the text of a `resolv.conf` that you have read |
| `DNS.same_name?(a, b)` | whether two names are the same for DNS (no case, a final dot is the same) |
| `DNS.encode_query(id, name, type)` and `DNS.decode(bytes)` | the codec |

The [nameservers](nameservers.md) page has the transports, the order, the timeouts and the checks. The [errors](errors.md) page has the kinds. The [codec](codec.md) page has the wire format and its limits.

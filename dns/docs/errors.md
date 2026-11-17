---
title: Errors
description: The kinds of the errors of the dns package and when each one happens.
weight: 3
---

An `error` of this package has a kind, tested with `e.is_a?("dns.nxdomain")`. The constants are `DNS.NXDOMAIN` and the like.

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


A query that ends in one of these kinds other than `dns.nxdomain` has been tried on every server first (see [nameservers](nameservers.md)), and the kind is the one of the last server.

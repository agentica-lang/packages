# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-17

Needs Agentica 0.33.1.

### Added

- A DNS client that asks the nameservers you choose, in order, each with its own timeout: `DNS.resolver`, `DNS.query`, `DNS.addresses`, `DNS.lookup` and `DNS.lookuper` (the shape of the `resolver:` of http-client).
- Transports: DNS over TCP (`Server.Tcp`, RFC 7766), over TLS (`Server.Tls`, RFC 7858, with the certificate name apart from the address) and over HTTPS (`Server.Https`, RFC 8484).
- Every answer is checked for its id, the QR flag and its question; the names compare without case (`DNS.same_name?`).
- A and AAAA addresses with their TTLs, with CNAME chains followed up to `max_cnames`; only records of the class IN whose owner is in the chain.
- Kinds of errors: `dns.nxdomain` (ends the search), `dns.servfail`, `dns.refused`, `dns.truncated`, `dns.timeout`, `dns.network`, `dns.mismatch`, `dns.malformed`, `dns.cname_limit` and `dns.no_address`.
- `DNS.system_servers` and `DNS.parse_resolv_conf`: the nameservers of a `resolv.conf` (IP addresses only), read only when asked.
- The codec of RFC 1035, public: `DNS.encode_query` and `DNS.decode`. Name compression is read with a pointer that must go before its name and never into the header, at most 32 pointers, labels of 63 bytes and names of 255; counts and lengths are checked against the bytes; each name is read once per place, so a hostile message costs in proportion to its size.

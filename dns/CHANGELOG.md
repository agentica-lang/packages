# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `DNS.resolver`, `DNS.query`, `DNS.addresses`, `DNS.lookup` and `DNS.lookuper`: queries over TCP (`Server.Tcp`) and TLS (`Server.Tls`), nameservers tried in order with a timeout each, answers checked (id, QR, question), CNAME chains followed up to `max_cnames`, and the kinds `dns.nxdomain`, `dns.servfail`, `dns.refused`, `dns.truncated`, `dns.timeout`, `dns.network`, `dns.mismatch`, `dns.cname_limit` and `dns.no_address`.
- The codec of RFC 1035: `DNS.encode_query` and `DNS.decode`, with name compression (a pointer must go before its name, so no name reads a byte twice), a name read once per place, and bounded sizes.

# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] - 2026-11-21

- Add opt-in HTTP/2 for buffered requests, with HPACK, TLS ALPN, connection reuse and flow control.
- Multiplex HTTP/2 requests per connection, respecting peer concurrency and flow-control limits. Cancel individual streams and replace failed sessions on demand.
- Preserve buffered HTTP/2 responses at EOF and isolate malformed DATA to the affected stream.
- **Breaking:** Requires Agentica 0.35.0.

## [0.2.0] - 2026-11-20

Needs Agentica 0.34.0; CI runs it on Agentica 0.35.0.

### Added

- `HttpClient.cancel(stream)`: ends the body of a stream at once, interrupting a read that is waiting on its socket, so that the pool has its slot back and the next request does not wait for `body_idle_ms` or `read_timeout_ms` (#195). A connection with a response still to read is closed, never kept; a body read to its end keeps its connection, and cancelling then, twice, or after `close` does nothing.
- `body_idle_ms`, the longest a body may stay silent, apart from `read_timeout_ms`, for buffered responses and streams (#196). `none`, the default, takes `read_timeout_ms`, so a client that names neither behaves as before, and 0 is no limit.

### Fixed

- A resolver answer that is an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) connects to its IPv4 address, since std/http's `connect_to` refuses a mapped one.
- The probe after a failed send waits at most the read timeout of the call, not std/http's 300 s default.

### Changed

- `read_timeout_ms` is the time of the send and of the wait for the response head; the waits between body pieces are `body_idle_ms` (#196).
- The tests write the IMF-fixdate with the builtin `Time` instead of the deprecated `std/utc` (the tests need 0.35; the package code is unchanged).
- The dial path (`resolver` and `public_only`) connects with std/http's `connect_to` instead of setting fields of its `Connection`, so it no longer depends on them, and the "tested on 0.33.x only" note is gone (#154).
- The connect, the head and each read of a body take std/http's own timeouts (`connect_timeout_ms`, `timeout_ms` and `read_timeout_ms` of the connection) instead of a timeout set on a copy of the connection for each call.

## [0.1.0] - 2026-11-17

Needs Agentica 0.33.1, and is tested on 0.33.x only.

### Added

- `HttpClient.new`, `request`, `get`, `head`, `delete`, `post`, `put`, `patch` and `close`: an HTTP/1.1 client with a pool of keep-alive connections per origin (on the `pool` package), `base_url`, client headers, and timeouts for the connect, each read, the whole request and the wait for a connection.
- Retries of idempotent requests after transient errors and statuses, with backoff, jitter and `Retry-After` (`max_retries`, `retry_delay_ms`, `max_retry_delay_ms`), all within `timeout_ms`, which bounds the whole call.
- Redirects, at most `max_redirects`: a 303 (and a 301 or 302 after a POST) turns into a GET, credentials are not sent to another origin, and https to http is refused.
- `resolver` and `public_only`, opt-in: the client then resolves the host itself, with a DNS cache (`dns_cache_ms`, 10 s), and `public_only` refuses loopback, private, link-local and other non-public addresses on the address the connection goes to.
- `params`, `json` bodies, `HttpClient.decode` into a type, `basic_auth` and `bearer_auth`, and request and response steps (`request_steps`, `response_steps`).
- gzip and deflate bodies are decoded (`decompress`, on by default), within `max_body_bytes`.
- `HttpClient.stream`: the body of a response as a channel of pieces, as the server sends them; `events` and `get_events` read it as server-sent events.

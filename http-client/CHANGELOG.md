# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `HttpClient.new`, `request`, `get`, `head`, `delete`, `post`, `put`, `patch` and `close`: an HTTP/1.1 client with a pool of keep-alive connections per origin (on the `pool` package), `base_url`, client headers, and timeouts for the connect, each read, the whole request and the wait for a connection.
- Retries of idempotent requests after transient errors and statuses, with backoff, jitter and `Retry-After` (`max_retries`, `retry_delay_ms`, `max_retry_delay_ms`), all within `timeout_ms`, which bounds the whole call.
- Redirects, at most `max_redirects`: a 303 (and a 301 or 302 after a POST) turns into a GET, credentials are not sent to another origin, and https to http is refused.
- `resolver` (the system's by default), a DNS cache (`dns_cache_ms`, 10 s) and `public_only`, which refuses loopback, private, link-local and other non-public addresses on the address the connection goes to.

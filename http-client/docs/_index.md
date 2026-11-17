---
title: http-client
description: An HTTP client with a pool of keep-alive connections per origin, and timeouts for the connect, each read, the whole request and the wait for a connection.
---

`http-client` sends HTTP/1.1 requests from an Agentica program, in the spirit of Elixir's Req. You make a `Client` once, and each request goes through a pool of keep-alive connections for its origin (scheme, host and port), made with the [pool](https://www.agentica-lang.com/packages/pool/) package. It is built on the `HTTP.start`, `send_request` and `read_body` calls of `std/http`.

The package is new: request and response steps, JSON helpers and streamed bodies come in the next releases.

## Install

Needs Agentica 0.33.1, and is tested on 0.33.x only: until 0.34.0 it sets the timeout of each call, and on the opt-in dial path (`resolver` or `public_only`) the address and server name of a connection, through fields of std/http's `Connection` that may change. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`, once it is released:

```sh
agentica add http-client https://github.com/agentica-lang/packages --tag http-client-0.1.0 --subdir http-client
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock` (with the `pool` package that it needs):

```toml
[dependencies]
http-client = { git = "https://github.com/agentica-lang/packages", tag = "http-client-0.1.0", subdir = "http-client" }
```

## Example

A server of `std/http`, and a client that sends it two requests on one connection:

```agentica
import HTTP from "std/http"
import HttpClient from "pkg/http-client/http_client"

def hello(request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "hello #{request.target}".bytes))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&hello)).unwrap!
  client = HttpClient.new(base_url: "http://127.0.0.1:#{HTTP.local_port(server)}").unwrap!
  for path in ["/a", "/b?x=1"]
    case HttpClient.get(client, path)
      ok(response) -> puts("#{response.status} #{String.from_bytes(response.body).unwrap_or("")}")
      error(e) -> puts("#{e.kind}: #{e.message}")
    end
  end

  HttpClient.close(client)
  HTTP.close_server(server)
end
```

```output
200 hello /a
200 hello /b?x=1
```

## API

```signature
HttpClient.new(base_url: String = "", headers: List[HTTP.Header] = [], connect_timeout_ms: Int = 10000, read_timeout_ms: Int = 30000, timeout_ms: Int = 60000, max_body_bytes: Int = 16777216, max_retries: Int = 3, retry_delay_ms: Int = 500, max_retry_delay_ms: Int = 30000, max_redirects: Int = 10, pool_size: Int = 10, pool_timeout_ms: Int = 5000, idle_ms: Int = 30000, resolver: Optional[Fn[String, Result[List[String]]]] = none, dns_cache_ms: Int = 10000, public_only: Bool = false, proxy: String = "", tls: Optional[TLS.Context] = none) -> Result[Client]
HttpClient.request(client: Client, method: String, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.get(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.head(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.delete(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.post(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.put(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.patch(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.close(client: Client, drain_ms: Int = 5000) -> Void
```

- The API is the module `http_client.agc` (`pkg/http-client/http_client`); the modules under `src/` are internal and may change in any release.
- A `url` that starts with `http://` or `https://` is used as it is; any other is a path (or a `?query`) joined to `base_url`. A URL with user info is refused.
- The `headers` of a call go over the client's headers of the same name. std/http adds `Host` and `Content-Length`.
- The client's `headers` go with every request, to whatever origin its URL names, not only to the one of `base_url`: give a secret such as `Authorization` to the calls that need it, or use a client per origin.
- A `Response` has `status`, `headers` (names in lowercase), `body` (`Bytes`, read whole) and `url`. A 4xx or 5xx is a response, not an error.
- `client.with(read_timeout_ms: 500)` gives a client with other values for its public fields (`base_url`, `headers`, the timeouts below, `max_body_bytes` and the retry and redirect settings), and it shares the pools of the first one. A request checks them as `new` does.
- Make the client in a task that lives as long as it does, such as `main`, and `close` it at the end: the requests in flight have `drain_ms` to end, and `close` returns once every task of the client has ended, so a test that closes its client leaves no task behind.

## Timeouts

- `connect_timeout_ms`: to open a connection (and its TLS handshake).
- `read_timeout_ms`: sending the request and the wait for the head of the response, then each wait for a piece of the body.
- `timeout_ms`: the whole call, from the call to the end of the last body: its tries, the waits between them and its redirects. Each wait is cut to what is left of it.
- `pool_timeout_ms`: the wait for a free connection of the origin, when all `pool_size` of them are in use.

## Retries

A `GET`, `HEAD`, `OPTIONS`, `TRACE`, `PUT` or `DELETE` (in any case) goes again after a connect or read timeout, a broken connection, or a 408, 429, 500, 502, 503 or 504. `max_retries` (0 for never) counts the retries of the whole call, its redirects included. A `POST` or `PATCH` is never sent twice. Before each try the client waits `retry_delay_ms`, doubled on each try up to `max_retry_delay_ms`, with jitter (between half of that and all of it). A `Retry-After` of the response, in seconds or as an HTTP date, is waited as it is; one over `max_retry_delay_ms` gives the response back at once. A wait that does not fit in what is left of `timeout_ms` gives the last response or error back at once, and so does the last try.

A retried `PUT` or `DELETE` may have been applied already: a broken connection or a read timeout does not say whether the server got the request. Those methods are idempotent, so a second time leaves the same state, but a server that counts them sees two. Set `max_retries: 0` where that matters.

## Redirects

A 301, 302, 303, 307 or 308 with a `Location` is followed, at most `max_redirects` times (0 gives the redirect back as the response); one more is an `http_client.redirect.too_many` error. The `Location` is read against the URL of the response, and the `url` of the final response says where the request ended.

- A 303 turns the request into a `GET` (a `HEAD` stays one), and so do a 301 and a 302 for a `POST`. That `GET` has no body and no `Content-Type`. A 307 and a 308 keep the method and the body.
- A redirect to another origin than the first request's goes without `Authorization` and `Cookie`, and so do the redirects after it; without `Proxy-Authorization` too, unless the client has a `proxy`, which carries every hop. Other headers, those of the client included, go on, and a 307 or 308 sends the body to the other origin as well.
- A redirect from `https` to `http`, and a `Location` that is not an `http` or `https` URL or has a space or a control character, are an `http_client.redirect.location` error.

## Resolving and public_only

By default std/http resolves the host of each connection, as it always does. A client with a `resolver` or with `public_only: true` takes the dial path instead: it resolves the host itself, with `resolver` (`DNS.lookup`, the system resolver, when none), and connects to one of its addresses, tried in order within `connect_timeout_ms`: each address gets an equal share of the time left, so one that never answers leaves time for the next. A resolver that has not answered within `connect_timeout_ms` is an `http_client.timeout.connect` error. The URL host still names the server: std/http writes it in `Host`, and for `https` it is the TLS server name and the name the certificate is checked against. A resolver is any `Fn[String, Result[List[String]]]`, such as `DNS.lookuper(resolver)` of the [dns](https://www.agentica-lang.com/packages/dns/) package. On the dial path its answers are kept `dns_cache_ms` (10 seconds by default, as aiosonic's `ttl_dns_cache`; 0 for no cache), shared by every connection of the client. Without `resolver` or `public_only`, `dns_cache_ms` has no effect until std/http has `connect_to` (agentica#1556, planned for 0.34.0). A host that does not resolve is an `http_client.dns` error.

With `public_only: true` the client refuses every address that is not public: loopback, private, link-local, carrier-grade NAT, documentation, multicast and the other special ranges, IPv4 and IPv6 (an IPv6 address that carries an IPv4 one is judged by it). A host with no public address is an `http_client.address_denied` error, and nothing is sent. This is the guard of a server that fetches URLs its users give (webhooks, link previews) against server-side request forgery (SSRF):

- The check is on the address the connection goes to, after the resolution, so a DNS answer that changes in between (DNS rebinding) cannot reach a private address. An IP literal in the URL is checked too.
- Each redirect is a new connection and is checked the same way.
- A `proxy` resolves the host itself, so `new` refuses a `resolver` or `public_only` together with one (`argument`).

Until std/http has `connect_to`, the dial path opens the connection to the address with std/http, does the TLS handshake for `https` itself, and then sets the `host`, `socket` and `scheme` fields of std/http's `Connection`. Those fields may change, which is why the dial path is opt-in and why the package is tested on 0.33.x only. With `connect_to` the client will pass the address to std/http instead, with the same behavior.

## The pool

Each origin has a pool of at most `pool_size` connections, made when a request needs one. After a response read to its end, its connection waits for the next request, unless the server said `Connection: close`. A connection is never reused after an error, after a body that ended with its close (no `Content-Length`, not chunked), past the `Keep-Alive: timeout` of the server (a day at most), or once the server has closed it or written to it while it was idle: the next request opens a new one. One unused for `idle_ms` is closed. When the connection of a request turns out to be closed before the request is written, the request goes on a new one.

The connections belong to the client, not to the task of the request that opened them: a task that is cancelled or crashes ends only the connection it was using. The pool of an origin that no request used for `timeout_ms` and then `idle_ms` is closed, so a client that talks to many origins keeps only those in use.

## Errors

Each error has a kind, so a caller tests `e.is_a?("http_client.timeout")` or a kind below, never the text:

| Kind | When |
| --- | --- |
| `http_client.timeout.pool` | no connection was free within `pool_timeout_ms` |
| `http_client.timeout.connect` | the connect took longer than `connect_timeout_ms` |
| `http_client.timeout.read` | the server sent nothing for `read_timeout_ms` |
| `http_client.timeout.request` | the request took longer than `timeout_ms` |
| `http_client.pool_full` | 1000 requests wait for a connection of the origin already |
| `http_client.network` | the connect failed, or the connection broke |
| `http_client.too_large` | the body is over `max_body_bytes` |
| `http_client.dns` | the host does not resolve |
| `http_client.address_denied` | `public_only` and the host has no public address |
| `http_client.redirect.too_many` | more than `max_redirects` redirects |
| `http_client.redirect.location` | a redirect whose `Location` cannot be followed |
| `http_client.closed` | the client is closed |
| `http_client.crashed` | the task of the request crashed: a bug, which a retry does not fix |
| `argument` | a bad URL, setting, method or header; nothing was sent, and the connection stays |

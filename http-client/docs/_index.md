---
title: http-client
description: An HTTP client with a pool of keep-alive connections per origin, and timeouts for the connect, each read, the whole request and the wait for a connection.
---

`http-client` sends HTTP/1.1 requests from an Agentica program, in the spirit of Elixir's Req. You make a `Client` once, and each request goes through a pool of keep-alive connections for its origin (scheme, host and port), made with the [pool](https://www.agentica-lang.com/packages/pool/) package. It is built on the `HTTP.start`, `send_request` and `read_body` calls of `std/http`.

The package is new: retries, redirects, request and response steps, JSON helpers and streamed bodies come in the next releases.

## Install

Needs Agentica 0.33.1 or later. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`, once it is released:

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
HttpClient.new(base_url: String = "", headers: List[HTTP.Header] = [], connect_timeout_ms: Int = 10000, read_timeout_ms: Int = 30000, timeout_ms: Int = 60000, max_body_bytes: Int = 16777216, pool_size: Int = 10, pool_timeout_ms: Int = 5000, idle_ms: Int = 30000, proxy: String = "", tls: Optional[TLS.Context] = none) -> Result[Client]
HttpClient.request(client: Client, method: String, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.get(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.head(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.delete(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.post(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.put(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.patch(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.close(client: Client, drain_ms: Int = 5000) -> Void
```

- A `url` that starts with `http://` or `https://` is used as it is; any other is a path (or a `?query`) joined to `base_url`. A URL with user info is refused.
- The `headers` of a call go over the client's headers of the same name. std/http adds `Host` and `Content-Length`.
- A `Response` has `status`, `headers` (names in lowercase), `body` (`Bytes`, read whole) and `url`. A 4xx or 5xx is a response, not an error.
- `client.with(read_timeout_ms: 500)` gives a client with other values for its public fields (`base_url`, `headers` and the timeouts below), and it shares the pools of the first one.
- Make the client in a task that lives as long as it does, such as `main`, and `close` it at the end: the requests in flight have `drain_ms` to end.

## Timeouts

- `connect_timeout_ms`: to open a connection (and its TLS handshake).
- `read_timeout_ms`: each wait for bytes of the response, the head and each piece of the body.
- `timeout_ms`: the whole request, from the call to the end of the body. Each wait is cut to what is left of it.
- `pool_timeout_ms`: the wait for a free connection of the origin, when all `pool_size` of them are in use.

## The pool

Each origin has a pool of at most `pool_size` connections, made when a request needs one. After a response read to its end, its connection waits for the next request, unless the server said `Connection: close`. A connection is never reused after an error, past the `Keep-Alive: timeout` of the server, or once the server has closed it while it was idle: the next request opens a new one. One unused for `idle_ms` is closed.

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
| `http_client.closed` | the client is closed |
| `argument` | a bad URL or setting |

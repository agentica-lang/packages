---
title: http-client
description: An HTTP client with a pool of keep-alive connections per origin, and timeouts for the connect, the response head, the idle body, the whole request and the wait for a connection.
---

`http-client` sends HTTP requests from an Agentica program, in the spirit of Elixir's Req. You make a `Client` once, and each request goes through a pool of keep-alive connections for its origin (scheme, host and port), made with the [pool](https://www.agentica-lang.com/packages/pool/) package. HTTP/1.1 uses `std/http`.

## Install

The released version needs Agentica 0.34.0. Add it in a project with an `agentica.toml`, with its prefixed tag and its folder as `--subdir`:

```sh
agentica add http-client agentica-lang/packages --tag http-client-0.2.0 --subdir http-client
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock` (with its `pool` dependency):

```toml
[dependencies]
http-client = { git = "https://github.com/agentica-lang/packages", tag = "http-client-0.2.0", subdir = "http-client" }
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
HttpClient.new(base_url: String = "", headers: List[HTTP.Header] = [], params: List[URI.Pair] = [], connect_timeout_ms: Int = 10000, read_timeout_ms: Int = 30000, body_idle_ms: Optional[Int] = none, timeout_ms: Int = 60000, max_body_bytes: Int = 16777216, max_retries: Int = 3, retry_delay_ms: Int = 500, max_retry_delay_ms: Int = 30000, max_redirects: Int = 10, decompress: Bool = true, request_steps: List[Fn[Request, Result[Request]]] = [], response_steps: List[Fn[Response, Result[Response]]] = [], pool_size: Int = 10, pool_timeout_ms: Int = 5000, idle_ms: Int = 30000, resolver: Optional[Fn[String, Result[List[String]]]] = none, dns_cache_ms: Int = 10000, public_only: Bool = false, proxy: String = "", tls: Optional[TLS.Context] = none, protocol: HttpClient.Protocol = HttpClient.Protocol.Http1) -> Result[Client]
HttpClient.request(client: Client, method: String, url: String, body: Optional[Bytes] = none, json: Optional[JSON.Value] = none, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.get(client: Client, url: String, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.head(client: Client, url: String, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.delete(client: Client, url: String, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.post(client: Client, url: String, body: Optional[Bytes] = none, json: Optional[JSON.Value] = none, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.put(client: Client, url: String, body: Optional[Bytes] = none, json: Optional[JSON.Value] = none, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.patch(client: Client, url: String, body: Optional[Bytes] = none, json: Optional[JSON.Value] = none, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Response]
HttpClient.decode(response: Response, codec: Codec[T]) -> Result[T]
HttpClient.basic_auth(user: String, password: String) -> Result[HTTP.Header]
HttpClient.bearer_auth(token: String) -> HTTP.Header
HttpClient.stream(client: Client, method: String, url: String, body: Optional[Bytes] = none, json: Optional[JSON.Value] = none, params: List[URI.Pair] = [], headers: List[HTTP.Header] = []) -> Result[Stream]
HttpClient.cancel(stream: Stream) -> Void
HttpClient.events(stream: Stream, max_event_bytes: Int = 1048576) -> Channel[Result[Event]]
HttpClient.get_events(client: Client, url: String, params: List[URI.Pair] = [], headers: List[HTTP.Header] = [], max_event_bytes: Int = 1048576) -> Result[Channel[Result[Event]]]
HttpClient.close(client: Client, drain_ms: Int = 5000) -> Void
```

- The API is the module `http_client.agc` (`pkg/http-client/http_client`); the modules under `src/` are internal and may change in any release.
- A `url` that starts with `http://` or `https://` is used as it is; any other is a path (or a `?query`) joined to `base_url`. A URL with user info is refused.
- The `headers` of a call go over the client's headers of the same name. std/http adds `Host` and `Content-Length`.
- `params` (`URI.Pair` of `std/uri`) go in the query, encoded as a form (`URI.encode_www_form`): after the query of the URL, the client's first, then the call's.
- The client's `headers` go with every request, to whatever origin its URL names, not only to the one of `base_url`: give a secret such as `Authorization` to the calls that need it, or use a client per origin.
- A `Response` has `status`, `headers` (names in lowercase), `body` (`Bytes`, read whole) and `url`. A 4xx or 5xx is a response, not an error.
- `client.with(read_timeout_ms: 500)` gives a client with other values for its public fields (`base_url`, `headers`, `params`, the timeouts below, `max_body_bytes`, the retry and redirect settings, `decompress` and the steps), and it shares the pools of the first one. A request checks them as `new` does.
- Make the client in a task that lives as long as it does, such as `main`, and `close` it at the end: the requests in flight have `drain_ms` to end, and `close` returns once every task of the client has ended, so a test that closes its client leaves no task behind.

## HTTP/2 (unreleased)

The unreleased transport needs Agentica 0.35.0 and uses [hpack](https://www.agentica-lang.com/packages/hpack/) for header blocks. HTTP/1.1 is the default. To use HTTP/2, pass `protocol: HttpClient.Protocol.Http2` to `HttpClient.new`, then call the same `get`, `post` or `request` functions. The setting is fixed for that client's pools. For `https://`, the peer must negotiate `h2` via ALPN. If you supply a TLS context, configure it to advertise `h2`. For `http://`, the peer must accept the HTTP/2 connection preface directly.

Each HTTP/2 connection multiplexes up to 100 active streams, or the peer’s lower limit. Requests reuse sessions with space before opening more sockets, up to `pool_size` per origin. When all sessions are busy, up to 1,000 requests per origin can wait in arrival order within `pool_timeout_ms` and the whole request deadline. A full queue returns `http_client.timeout.pool`. Request and response bodies are buffered, with separate flow-control windows for the connection and each stream. A request timeout cancels its stream while other requests on the connection can continue. The current HTTP/2 transport supports direct connections and buffered responses. Calls to the proxy, streaming, and SSE APIs with HTTP/2 return an argument error.

## JSON, auth and steps

`json` sends a `JSON.Value` as the body, with `content-type: application/json` unless the call names another; `body` sends bytes as they are, and a call with both is an `argument` error. `HttpClient.decode(response, User.codec)` reads a JSON body into a type, and a body that is not that JSON is an `http_client.decode` error. `basic_auth` and `bearer_auth` make the `authorization` header, for the `headers` of the client or of a call; a user name with a `:` is an `argument` error (RFC 7617).

The steps are Req's model of plugins. `request_steps` run in order on each call, after `base_url`, `params`, `json` and the headers are applied and before the first try: each takes a `Request` (`method`, `url`, `headers`, `body`) and gives the one to send. They run once, not again for each retry or redirect, so a step that signs the URL signs only the first one. `response_steps` run in order on the final response, after the retries, the redirects and the decoding of the body. An error of a step is the error of the call.

```agentica
import HTTP from "std/http"
import HttpClient from "pkg/http-client/http_client"

struct Todo
  id: Int
  title: String
end

def created(request: HTTP.Request) -> Result[HTTP.Response]
  todo = try JSON.decode(try String.from_bytes(request.body), Todo)
  sent_by = HTTP.header_values(request.headers, "x-request-id").join(",")
  body = JSON.encode(todo.with(id: 7, title: "#{todo.title} (#{sent_by})"))
  ok(HTTP.Response(status: 201, headers: [], body: body.bytes))
end

def tagged(request: HttpClient.Request) -> Result[HttpClient.Request]
  ok(request.with(headers: request.headers.push(HTTP.Header(name: "x-request-id", value: "r1"))))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&created)).unwrap!
  client = HttpClient.new(
    base_url: "http://127.0.0.1:#{HTTP.local_port(server)}",
    headers: [HttpClient.bearer_auth("secret")],
    request_steps: [&tagged],
  ).unwrap!

  response = HttpClient.post(client, "/todos", json: some(JSON.from(Todo(id: 0, title: "milk")))).unwrap!
  puts(response.status)
  puts(HttpClient.decode(response, Todo.codec))
  HttpClient.close(client)
  HTTP.close_server(server)
end
```

```output
201
ok(Todo(id: 7, title: "milk (r1)"))
```

## Compressed bodies

With `decompress` (the default) a request asks for `accept-encoding: gzip, deflate`, unless it names its own, and a body in `gzip` or `deflate` (the zlib format, or raw DEFLATE as some servers send it) is decoded before the response is given, without its `content-encoding` and `content-length` headers. The decoded body is also at most `max_body_bytes` (`http_client.too_large`), and one that does not decode is an `http_client.decode` error. A body in another coding stays as it came, and so does a 206, the part of a body whose coding applies to the whole. std's decoder takes one gzip member, so a body of several (RFC 1952 allows it, servers rarely send it) is an `http_client.decode` error. `decompress: false` sends no `accept-encoding` and decodes nothing.

## Streams and server-sent events

`stream` sends a request as `request` does, and gives a `Stream` once the head of the response has come: `status`, `headers`, `url`, and `body`, a channel that gives `ok(piece)` for each piece of the body as the server sends it, then one `error` if the body fails or is cut short, and closes at its end. A body that closes without an error came whole.

- Read `body` to its end, or `cancel` it: the connection goes back to the pool after the end. A body cancelled before its end closes its connection at once, so the next request does not wait for the pool; closing `body` alone leaves the pump task to notice at its next read, which may be `body_idle_ms` away, and its connection closes then.
- `timeout_ms` bounds the call up to the head. After it, each piece has `body_idle_ms` to come and the reader has `read_timeout_ms` to take it: `body` holds one piece at a time, and the time starts again at each take. A body that sends nothing for `body_idle_ms`, or a reader that takes nothing for `read_timeout_ms`, gets an `http_client.timeout.read` error after the piece that waited, and the connection closes.
- `cancel(stream)` is safe at any time: a body that ended by itself, with its last piece or with an error, is left as it was; a client that is closed has already ended its streams; and a second `cancel` does nothing. A reader that is waiting gets an `http_client.cancelled` error, or the end of a body that closed first.
- The pool of the origin stays while a stream is open, however long it lasts.
- `close` ends the streams of the client: their readers get an `http_client.closed` error, and `close` returns once their tasks have ended.
- A stream asks for no compression and decodes none (a server that compresses all the same gives its coded bytes as they came, with `content-encoding` in `headers`), `max_body_bytes` does not apply to it, and `response_steps` do not run. Request steps, retries and redirects work as for `request`: a response that is retried or redirected is read whole and dropped, and so is one that could be retried but has no time left, which then comes as one piece.

`events(stream)` reads the body as server-sent events (`text/event-stream`), in a task of its own: an `Event` has `event` (`message` when the server names none), `data` (the `data` lines joined by newlines) and `id` (the last event ID). The channel ends with an error as the body does, and also for an event over `max_event_bytes` (`http_client.too_large`) or a reader that took no event for `read_timeout_ms` (`http_client.timeout.read`). Closing the channel of the events closes the body. Each event has `read_timeout_ms` from when it is given, as a piece does. `get_events(client, url)` is a `GET` with `accept: text/event-stream` and its events; a response that is not a 2xx with `content-type: text/event-stream` is an `http_client.events` error that names its status and type in its message only: to branch on the status, call `stream` and look at `status` before `events`, which reads any stream. A stream has one reader of events: a second `events` call gives a channel with an `argument` error. The end of the task that called `events`, by a cancel or a crash, closes the body too. The client does not reconnect: to go on after the end, send the `id` of the last event in a `last-event-id` header.

```agentica
import HTTP from "std/http"
import HttpClient from "pkg/http-client/http_client"

def ticks(_request: HTTP.Request) -> Result[HTTP.Response]
  text = "event: tick\ndata: 1\n\n: a comment\ndata: two\ndata: lines\nid: 2\n\n"
  ok(HTTP.Response(status: 200, headers: [HTTP.Header(name: "content-type", value: "text/event-stream")], body: text.bytes))
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&ticks)).unwrap!
  client = HttpClient.new(base_url: "http://127.0.0.1:#{HTTP.local_port(server)}").unwrap!
  events = HttpClient.get_events(client, "/ticks").unwrap!
  for item in events.lazy(5_000).to_a.unwrap!
    case item
      ok(event) -> puts("#{event.event} #{event.data.inspect} #{event.id.inspect}")
      error(e) -> puts("#{e.kind}: #{e.message}")
    end
  end

  HttpClient.close(client)
  HTTP.close_server(server)
end
```

```output
tick "1" ""
message "two\nlines" "2"
```

## Timeouts

- `connect_timeout_ms`: to open a connection (and its TLS handshake).
- `read_timeout_ms`: sending the request and the wait for the head of the response; then, for a stream, the time its reader has to take each piece.
- `body_idle_ms`: each wait between two pieces of a body, for a buffered response and for a stream. `none`, the default, takes the value of `read_timeout_ms`, which is what a client had before the two were separate; 0 is no limit, and a buffered body is then bounded by `timeout_ms` alone, a stream by its reader, `cancel` or `close`. A slow head does not relax this budget, and a generous one does not have to be shared with the body.
- `timeout_ms`: the whole call, from the call to the end of the last body: its tries, the waits between them and its redirects. Each wait is cut to what is left of it.
- `pool_timeout_ms`: the wait for a free connection of the origin, when all `pool_size` of them are in use. A request that waits for one spends none of its other budgets while it waits: the connect, the head and the body start when it has a connection, each cut to what is left of `timeout_ms`, which covers the wait too.

## Retries

A `GET`, `HEAD`, `OPTIONS`, `TRACE`, `PUT` or `DELETE` (in any case) goes again after a connect or read timeout, a broken connection, or a 408, 429, 500, 502, 503 or 504. `max_retries` (0 for never) counts the retries of the whole call, its redirects included. A `POST` or `PATCH` is never sent twice. Before each try the client waits `retry_delay_ms`, doubled on each try up to `max_retry_delay_ms`, with jitter (between half of that and all of it). A `Retry-After` of the response, in seconds or as an HTTP date, is waited as it is; one over `max_retry_delay_ms` gives the response back at once. A wait that does not fit in what is left of `timeout_ms` gives the last response or error back at once, and so does the last try.

A retried `PUT` or `DELETE` may have been applied already: a broken connection or a read timeout does not say whether the server got the request. Those methods are idempotent, so a second time leaves the same state, but a server that counts them sees two. Set `max_retries: 0` where that matters.

## Redirects

A 301, 302, 303, 307 or 308 with a `Location` is followed, at most `max_redirects` times (0 gives the redirect back as the response); one more is an `http_client.redirect.too_many` error. The `Location` is read against the URL of the response, and the `url` of the final response says where the request ended.

- A 303 turns the request into a `GET` (a `HEAD` stays one), and so do a 301 and a 302 for a `POST`. That `GET` has no body and no `Content-Type`. A 307 and a 308 keep the method and the body.
- A redirect to another origin than the first request's goes without `Authorization` and `Cookie`, and so do the redirects after it; without `Proxy-Authorization` too, unless the client has a `proxy`, which carries every hop. Other headers, those of the client included, go on, and a 307 or 308 sends the body to the other origin as well.
- A redirect from `https` to `http`, and a `Location` that is not an `http` or `https` URL or has a space or a control character, are an `http_client.redirect.location` error.

## Resolving and public_only

By default std/http resolves the host of each connection, as it always does. A client with a `resolver` or with `public_only: true` takes the dial path instead: it resolves the host itself, with `resolver` (`DNS.lookup`, the system resolver, when none), and connects to one of its addresses, tried in order within `connect_timeout_ms`: each address gets an equal share of the time left, so one that never answers leaves time for the next. A resolver that has not answered within `connect_timeout_ms` is an `http_client.timeout.connect` error. The URL host still names the server: std/http writes it in `Host`, and for `https` it is the TLS server name and the name the certificate is checked against. A resolver is any `Fn[String, Result[List[String]]]`, such as `DNS.lookuper(resolver)` of the [dns](https://www.agentica-lang.com/packages/dns/) package. On the dial path its answers are kept `dns_cache_ms` (10 seconds by default, as aiosonic's `ttl_dns_cache`; 0 for no cache), shared by every connection of the client. Without `resolver` or `public_only`, `dns_cache_ms` has no effect, since std/http resolves the host. A host that does not resolve is an `http_client.dns` error.

With `public_only: true` the client refuses every address that is not public: loopback, private, link-local, carrier-grade NAT, documentation, multicast and the other special ranges, IPv4 and IPv6 (an IPv6 address that carries an IPv4 one is judged by it). A host with no public address is an `http_client.address_denied` error, and nothing is sent. This is the guard of a server that fetches URLs its users give (webhooks, link previews) against server-side request forgery (SSRF):

- The check is on the address the connection goes to, after the resolution, so a DNS answer that changes in between (DNS rebinding) cannot reach a private address. An IP literal in the URL is checked too.
- Each redirect is a new connection and is checked the same way.
- A `proxy` resolves the host itself, so `new` refuses a `resolver` or `public_only` together with one (`argument`).

The client gives std/http the address with `connect_to`, so the connection goes to the address that was checked while std/http uses the URL host for `Host`, the TLS server name and the certificate check. An address that std/http refuses as a `connect_to` (IPv4-mapped, `0.0.0.0` and `::`) is not a destination for the client either: it is an error of that connect.

## The pool

Each HTTP/1.1 origin has a pool of at most `pool_size` connections, made when a request needs one. After a response read to its end, its connection waits for the next request, unless the server said `Connection: close`. A connection is never reused after an error, after a body that ended with its close (no `Content-Length`, not chunked), past the `Keep-Alive: timeout` of the server (a day at most), or once the server has closed it or written to it while it was idle: the next request opens a new one. One unused for `idle_ms` is closed. When the connection of a request turns out to be closed before the request is written, the request goes on a new one.

Connections belong to the client. When an HTTP/1.1 request task is cancelled or crashes, its connection ends. The HTTP/2 origin instead cancels the affected stream or removes the request from its queue. The pool of an origin that no request used for `timeout_ms` and then `idle_ms` is closed, so a client that talks to many origins keeps only those in use.

## Errors

Each error has a kind, so a caller tests `e.is_a?("http_client.timeout")` or a kind below, never the text:

| Kind | When |
| --- | --- |
| `http_client.timeout.pool` | no connection was free within `pool_timeout_ms` |
| `http_client.timeout.connect` | the connect took longer than `connect_timeout_ms` |
| `http_client.timeout.read` | the server sent nothing for `body_idle_ms`, or the reader of a stream took no piece for `read_timeout_ms` |
| `http_client.timeout.request` | the request took longer than `timeout_ms` |
| `http_client.pool_full` | 1000 requests wait for a connection of the origin already |
| `http_client.network` | the connect failed, or the connection broke |
| `http_client.too_large` | the body is over `max_body_bytes`, before or after its decoding, or an event is over `max_event_bytes` |
| `http_client.decode` | a compressed body that does not decode, a body that `decode` cannot read, or events that are not UTF-8 |
| `http_client.events` | `get_events` got a response that is not a 2xx event stream |
| `http_client.dns` | the host does not resolve |
| `http_client.address_denied` | `public_only` and the host has no public address |
| `http_client.redirect.too_many` | more than `max_redirects` redirects |
| `http_client.redirect.location` | a redirect whose `Location` cannot be followed |
| `http_client.closed` | the client is closed, before the request or during its stream |
| `http_client.cancelled` | `HttpClient.cancel` ended the body of a stream before its end |
| `http_client.crashed` | the task of the request crashed: a bug, which a retry does not fix |
| `argument` | a bad URL, setting, method or header, or both `body` and `json`; nothing was sent, and the connection stays |

The error of a step is given as it is, with its own kind.

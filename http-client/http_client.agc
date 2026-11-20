## An HTTP client with a pool of keep-alive connections per origin, in the spirit of Elixir's Req: make a `Client`
## once with `new`, send requests with `get`, `post` and the others, and `close` it at the end.
##
## Each origin (scheme, host and port) has a pool of `pool_size` connections, made when a request first needs one. A
## request waits at most `pool_timeout_ms` for a free connection, at most `connect_timeout_ms` to connect, at most
## `read_timeout_ms` for the send and the head and at most `body_idle_ms` for each wait for the body, and at most
## `timeout_ms` for the whole call. A connection is kept for the next request only when its response was read to its
## end and the server did not close it. An idempotent request goes again after a transient error or status
## (`src/retry.agc`), a redirect is followed (`src/redirect.agc`), and a gzip or deflate body is decoded
## (`src/encoding.agc`). The request steps of the client change each request before it goes, and its response steps
## change each response it gives (`Request`).

import Dial from "src/dial"
import Encoding from "src/encoding"
import Exchange from "src/exchange"
import HTTP from "std/http"
import Pool from "pkg/pool/pool"
import Pools from "src/pools"
import ProtocolTypes from "src/protocol"
import Redirect from "src/redirect"
import {Hop} from "src/redirect"
import Retry from "src/retry"
import Sse from "src/sse"
import URI from "std/uri"
import Url from "src/url"

export Exchange.Response
export ProtocolTypes.Protocol
export Sse.Event

## A request as the request steps see it: the method, the whole URL with its query, the headers and the body.
struct Request
  method: String
  url: String
  headers: List[HTTP.Header]
  body: Bytes
end

## A response whose body comes in pieces (`stream`): `body` gives `ok(piece)` for each piece as the server sends it,
## then one `error` if the body fails or is cut short (no piece for `body_idle_ms`, a reader that took nothing for
## `read_timeout_ms`, the client closed, or `cancel`), and closes at its end. A body that closes without an error came
## whole.
struct Stream
  status: Int
  headers: List[HTTP.Header]
  url: String
  body: Channel[Result[Bytes]]

  private

  read_timeout_ms: Int
  body_idle_ms: Int
  pools: Pools.Pools
  relayed: Channel[Bool]
  relay_down: Channel[Bool]
  ended: Channel[Bool]
  worker: Optional[Task[Result[Exchange.Response]]]
end

## A client. The public fields apply to each request, and `client.with(...)` gives a client with other values that
## shares the pools: `client.with(read_timeout_ms: 500)`. `headers` go with every request, under the headers of the
## call, and `params` go in the query of every request, before those of the call.
struct Client
  base_url: String
  headers: List[HTTP.Header]
  params: List[URI.Pair]
  connect_timeout_ms: Int
  read_timeout_ms: Int
  body_idle_ms: Optional[Int]
  timeout_ms: Int
  max_body_bytes: Int
  max_retries: Int
  retry_delay_ms: Int
  max_retry_delay_ms: Int
  max_redirects: Int
  decompress: Bool
  request_steps: List[Fn[Request, Result[Request]]]
  response_steps: List[Fn[Exchange.Response, Result[Exchange.Response]]]

  private

  pools: Pools.Pools
  proxied: Bool
  protocol: ProtocolTypes.Protocol
end

## Makes a client. `base_url` is joined to the URL of a request that is a path (`/todos`); the pool settings are
## `pool_size` connections per origin, `pool_timeout_ms` of wait for one, and `idle_ms` after which an unused one is
## closed. An idempotent request is tried again at most `max_retries` times in all, after `retry_delay_ms` doubled on
## each try (at most `max_retry_delay_ms`); at most `max_redirects` redirects are followed (0 gives the redirect back).
## `timeout_ms` bounds the whole call, its tries, waits and redirects included. `read_timeout_ms` is the time of the
## send and of the wait for the response head, and `body_idle_ms` the longest a body may stay silent: `none` takes the
## value of `read_timeout_ms`, which is what a client had before the two were separate, and 0 is no idle limit (the
## whole request still bounds a buffered body). With a `resolver` (one such as
## `DNS.lookuper` of the dns package) or `public_only`, the client resolves a host itself (with the system's
## `DNS.lookup` when no resolver is given) and keeps the answers `dns_cache_ms` (0 for none); `public_only` refuses
## every address that is not public (loopback, private, link-local and the other special ranges), checked on the
## address the connection goes to. With neither, std/http resolves the host and `dns_cache_ms` has no effect. `proxy`
## (`http://host:port`) and `tls` (a client `TLS.Context`, the system trust when none) are those of std/http's
## `ClientOptions`; a proxy resolves the host itself, so it is refused with a `resolver` or `public_only`. With
## `decompress` the client asks for gzip or deflate (unless the request names its own `accept-encoding`) and decodes
## such a body. `request_steps` run in order on each call before its first try (not again for a retry or a redirect),
## and `response_steps` on its final response; an error of a step is the error of the call. Make the client in a task
## that lives as long as it does, such as `main`.
def new(
  base_url: String = "",
  headers: List[HTTP.Header] = [],
  params: List[URI.Pair] = [],
  connect_timeout_ms: Int = 10_000,
  read_timeout_ms: Int = 30_000,
  body_idle_ms: Optional[Int] = none,
  timeout_ms: Int = 60_000,
  max_body_bytes: Int = 16_777_216,
  max_retries: Int = 3,
  retry_delay_ms: Int = 500,
  max_retry_delay_ms: Int = 30_000,
  max_redirects: Int = 10,
  decompress: Bool = true,
  request_steps: List[Fn[Request, Result[Request]]] = [],
  response_steps: List[Fn[Exchange.Response, Result[Exchange.Response]]] = [],
  pool_size: Int = 10,
  pool_timeout_ms: Int = 5_000,
  idle_ms: Int = 30_000,
  resolver: Optional[Fn[String, Result[List[String]]]] = none,
  dns_cache_ms: Int = 10_000,
  public_only: Bool = false,
  proxy: String = "",
  tls: Optional[TLS.Context] = none,
  protocol: ProtocolTypes.Protocol = ProtocolTypes.Protocol.Http1,
) -> Result[Client]
  if pool_timeout_ms < 1 or idle_ms < 1 or pool_timeout_ms > MAX_MS or idle_ms > MAX_MS
    return argument("pool_timeout_ms and idle_ms must be 1 to #{MAX_MS}")
  end

  return argument("pool_size must be at least 1") if pool_size < 1
  return argument("dns_cache_ms must be 0 to #{MAX_MS}") if dns_cache_ms < 0 or dns_cache_ms > MAX_MS
  if not proxy.empty? and (resolver.some? or public_only)
    return argument("a proxy resolves the host itself: give no resolver and no public_only with it")
  end

  return argument("HTTP/2 proxy is not supported") if protocol == ProtocolTypes.Protocol.Http2 and not proxy.empty?

  cache: ATS[String, Dial.Resolved] = ATS.new()
  dialer = Dial.Dialer(
    own: resolver.some? or public_only,
    resolver: resolver.unwrap_or(&system_lookup),
    cache: cache,
    cache_ms: dns_cache_ms,
    public_only: public_only,
  )

  settings = Pools.Settings(
    size: pool_size,
    wait_ms: pool_timeout_ms,
    idle_ms: idle_ms,
    health_ms: [idle_ms, HEALTH_MS].min.unwrap!,
    options: HTTP.ClientOptions(max_body_bytes: MAX_REQUEST_BODY, proxy: proxy, tls: tls),
    dialer: dialer,
    protocol: protocol,
  )

  client = Client(
    base_url: base_url,
    headers: headers,
    params: params,
    connect_timeout_ms: connect_timeout_ms,
    read_timeout_ms: read_timeout_ms,
    body_idle_ms: body_idle_ms,
    timeout_ms: timeout_ms,
    max_body_bytes: max_body_bytes,
    max_retries: max_retries,
    retry_delay_ms: retry_delay_ms,
    max_retry_delay_ms: max_retry_delay_ms,
    max_redirects: max_redirects,
    decompress: decompress,
    request_steps: request_steps,
    response_steps: response_steps,
    pools: Pools.start(settings),
    proxied: not proxy.empty?,
    protocol: protocol,
  )

  case valid(client)
    ok(_) -> ok(client)
    error(e) ->
      Pools.close(client.pools, 0)
      error(e)
  end
end

## Sends a request and gives the whole response, after its retries and redirects. `body` is sent as it is; `json` is
## sent as JSON text with `content-type: application/json` (unless `headers` name another), and giving both is an
## `argument` error. `params` go in the query, after those of the client. A 4xx or 5xx is a response, not an error.
## An error has a kind: `http_client.timeout.pool`, `.connect`, `.read` or `.request` (all
## `http_client.timeout`), `http_client.pool_full` (1000 requests wait already), `http_client.network`,
## `http_client.too_large` (a body over `max_body_bytes`), `http_client.redirect.too_many` (over `max_redirects`),
## `http_client.redirect.location` (a `Location` that cannot be followed), `http_client.decode` (a body that does not
## decode), `http_client.closed`, `http_client.crashed` (a bug: the request's task crashed) or `argument` (a bad URL,
## method or header, or a bad client field), or that of a step.
def request(
  client: Client,
  method: String,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  first = try prepared(client, method, url, body, json, params, headers, client.decompress)
  got = try sent(client, first, false)
  response = try decoded(client, got.response)
  for step in client.response_steps
    response = try step.call(response)
  end

  ok(response)
end

## Sends a request as `request` does, and gives the response once its head has come: its body comes in pieces through
## `body` (`Stream`), as the server sends them, for a reader that is a task of the caller's. The client asks for no
## compression and decodes none, and runs no response steps. A response that is retried or redirected is read whole and
## dropped, as for `request`; so is one that cannot go again for lack of time, which then comes as one piece.
## `timeout_ms` bounds the call up to the head; after it, each piece has `body_idle_ms` to come and the reader has
## `read_timeout_ms` to take it (`body` holds one), else the body ends with an `http_client.timeout.read` error. Read
## `body` to its end, or `cancel` it, so that its slot in the pool comes free: a body read to its end leaves its
## connection for the next request, and a cancelled one closes it. A server that compresses all the same gives its
## coded bytes as they came, with its `content-encoding` in `headers`.
def stream(
  client: Client,
  method: String,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Stream]
  return argument("HTTP/2 streaming is not supported") if client.protocol == ProtocolTypes.Protocol.Http2
  first = try prepared(client, method, url, body, json, params, headers, false)
  got = try sent(client, first, true)
  case got.stream
    some(streamed) -> ok(streamed)
    none ->
      pieces: Channel[Result[Bytes]] = Channel.new(1)
      if not got.response.body.empty?
        _ = pieces.send(ok(got.response.body), 0)
      end

      pieces.close
      response = got.response
      ended: Channel[Bool] = Channel.new(1)
      ended.close
      ok(
        Stream(
          status: response.status,
          headers: response.headers,
          url: response.url,
          body: pieces,
          read_timeout_ms: client.read_timeout_ms,
          body_idle_ms: idle_limit(client),
          pools: client.pools,
          relayed: Channel.new(1),
          relay_down: Channel.new(1),
          ended: ended,
          worker: none,
        ),
      )
  end
end

## Interrupts the body of a stream that its socket is still reading, so that the pool has its slot back now instead of
## when `body_idle_ms` runs out: a connection with a response still to read is closed, never kept, and the next request
## opens a new one. `body` ends at once with an `http_client.cancelled` error. A body that ended by itself, a response
## read to its end included, is left as it was and keeps its connection; cancelling twice, or after `close`, does
## nothing.
def cancel(stream: Stream) -> Void
  if not stream.ended.closed?
    case stream.worker
      some(worker) -> Task.cancel(worker)
      none -> nil
    end

    _ = stream.body.send(Exchange.failure("the stream was cancelled", "cancelled"), 0)
  end

  stream.body.close
end

## The server-sent events of `stream`, read by a task of their own: `ok(event)` for each, then one `error` if the body
## fails or is cut short, an event is over `max_event_bytes` (`http_client.too_large`), or the reader took no event
## for `read_timeout_ms` (`http_client.timeout.read`); the channel closes at the end of the body. Closing it early
## closes the body, and so do the end of the task that called `events` (its relay ends with it) and `cancel` of the
## stream. It reads the body whatever the status and type of the response; `get_events` checks them. A stream has one
## reader of events: a second call gives a channel with an `argument` error. The client does not reconnect: a reader
## that wants to goes again with the `last-event-id` header, from the `id` of the last event.
def events(stream: Stream, max_event_bytes: Int = 1_048_576) -> Channel[Result[Sse.Event]]
  out: Channel[Result[Sse.Event]] = Channel.new(EVENT_PLACES)
  if stream.relayed.closed?
    refused: Result[Sse.Event] = argument("the events of this stream are read already")
    _ = out.send(refused, 0)
    out.close
    return out
  end

  stream.relayed.close
  relaying = Task.spawn do relay(stream, out, max_event_bytes) end
  Task.monitor(relaying, stream.relay_down) do |_down| true end
  out
end

## A `GET` request whose body comes as a stream of server-sent events, with `accept: text/event-stream` unless
## `headers` name another. A response that is not a 2xx with `content-type: text/event-stream` is an
## `http_client.events` error that names its status and type in its message, and its body is closed: to branch on the
## status, call `stream` and then `events`.
def get_events(
  client: Client,
  url: String,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
  max_event_bytes: Int = 1_048_576,
) -> Result[Channel[Result[Sse.Event]]]
  streamed = try stream(client, "GET", url, params: params, headers: merge([EVENT_STREAM], headers))
  type = HTTP.header_values(streamed.headers, "content-type").join(",")
  if streamed.status < 200 or streamed.status > 299 or not type.downcase.strip.start_with?("text/event-stream")
    cancel(streamed)
    return Exchange.failure("the response is #{streamed.status} #{type.inspect}, not an event stream", "events")
  end

  ok(events(streamed, max_event_bytes))
end

# The request of a call, before its first try: the URL with its params, the headers, the body and the steps.
def prepared(
  client: Client,
  method: String,
  url: String,
  body: Optional[Bytes],
  json: Optional[JSON.Value],
  params: List[URI.Pair],
  headers: List[HTTP.Header],
  compressed: Bool,
) -> Result[Request]
  try valid(client)
  return argument("give a body or json, not both") if body.some? and json.some?

  first = Request(
    method: method,
    url: Url.to_s(Url.with_query(try Url.resolve(client.base_url, url), URI.encode_www_form(client.params + params))),
    headers: merge(client.headers, headers),
    body: body.unwrap_or(NO_BODY),
  )

  if json.some?
    first = first.with(body: JSON.encode(json.unwrap!).bytes, headers: merge([JSON_TYPE], first.headers))
  end

  if compressed
    first = first.with(headers: merge([ACCEPT_ENCODING], first.headers))
  end

  for step in client.request_steps
    first = try step.call(first)
  end

  ok(first)
end

## The body of the response read as JSON into the type of `codec`: `HttpClient.decode(response, User.codec)`. A body
## that is not that JSON is an `http_client.decode` error.
def decode[T](response: Exchange.Response, codec: Codec[T]) -> Result[T]
  case String.from_bytes(response.body)
    ok(text) ->
      case codec.decode(text)
        ok(value) -> ok(value)
        error(e) -> Exchange.failure("the body is not the JSON wanted", "decode", some(e))
      end

    error(e) -> Exchange.failure("the body is not UTF-8", "decode", some(e))
  end
end

## The `authorization` header of HTTP Basic, for `headers`.
## A user name with a `:` cannot be told from the password (RFC 7617), and is an `argument` error.
def basic_auth(user: String, password: String) -> Result[HTTP.Header]
  return argument("a basic auth user name cannot hold a colon") if user.include?(":")

  ok(HTTP.Header(name: "authorization", value: "Basic #{Base64.strict_encode64("#{user}:#{password}".bytes)}"))
end

## The `authorization` header of a bearer token, for `headers`.
def bearer_auth(token: String) -> HTTP.Header = HTTP.Header(name: "authorization", value: "Bearer #{token}")

## A `GET` request.
def get(
  client: Client,
  url: String,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "GET", url, params: params, headers: headers)
end

## A `HEAD` request: the response has no body.
def head(
  client: Client,
  url: String,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "HEAD", url, params: params, headers: headers)
end

## A `DELETE` request.
def delete(
  client: Client,
  url: String,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "DELETE", url, params: params, headers: headers)
end

## A `POST` request with `body` or `json`.
def post(
  client: Client,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "POST", url, body, json, params, headers)
end

## A `PUT` request with `body` or `json`.
def put(
  client: Client,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "PUT", url, body, json, params, headers)
end

## A `PATCH` request with `body` or `json`.
def patch(
  client: Client,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  request(client, "PATCH", url, body, json, params, headers)
end

## Closes the pools: the requests in flight have `drain_ms` to end, then their connections close. A request after the
## close is an `http_client.closed` error.
def close(client: Client, drain_ms: Int = 5_000) -> Void
  Pools.close(client.pools, drain_ms)
end

private

NO_BODY = "".bytes
JSON_TYPE = HTTP.Header(name: "content-type", value: "application/json")
ACCEPT_ENCODING = HTTP.Header(name: "accept-encoding", value: Encoding.ACCEPTED)
# The largest request body that std/http sends.
MAX_REQUEST_BODY = 67_108_864
# The largest time setting: a year, far from an overflow when it is added to a clock.
MAX_MS = 31_536_000_000
# The health tick of each pool checks its idle connections and closes those unused for `idle_ms`.
HEALTH_MS = 5_000
# How long a try that ran out of time has to end once cancelled.
CANCEL_MS = 1_000
EVENT_STREAM = HTTP.Header(name: "accept", value: "text/event-stream")
# The events read and not yet given that the relay holds before it stops reading the body; the channel of the events
# holds one, and a place for the error that ends it. A piece of the body comes within `body_idle_ms`, or the body
# ends: the relay waits that long, and a little more. It looks at its channels every `RELAY_POLL_MS` while it holds
# events, and every `RELAY_IDLE_MS` while it waits for the body alone, which is when a reader's close is seen.
EVENTS = 16
EVENT_PLACES = 2
RELAY_SLACK_MS = 1_000
RELAY_POLL_MS = 5
RELAY_IDLE_MS = 100

# What a try gives: the response, whole, or its head and the stream of its body.
struct Got
  response: Exchange.Response
  stream: Optional[Stream]
end

# What the relay holds: the parser, the events read and not yet given, when it gave the last one and heard the body
# last, and whether the body ended.
struct Relaying
  parser: Sse.Parser
  pending: List[Sse.Event]
  given_at: Int
  heard_at: Int
  ended: Bool
end

# The request after its retries and redirects.
def sent(client: Client, first: Request, streamed: Bool) -> Result[Got]
  target = try Url.resolve(client.base_url, first.url)
  deadline = Time.monotonic_ms() + client.timeout_ms
  policy = Retry.Policy(
    max_retries: client.max_retries,
    delay_ms: client.retry_delay_ms,
    max_delay_ms: client.max_retry_delay_ms,
  )

  hop = Hop(method: first.method, target: target, headers: first.headers, body: first.body)
  tries = 0
  redirects = 0
  while redirects <= client.max_redirects
    result = once(client, hop, deadline, streamed, tries)
    case Retry.wait_ms(policy, hop.method, responded(result), tries, Time.now_ms(), &jitter)
      some(ms) if Time.monotonic_ms() + ms < deadline ->
        dropped(result)
        Task.sleep(ms)
        tries = tries + 1
        next
      _ -> nil
    end

    got = try result
    location = Redirect.location(got.response)
    return ok(got) if client.max_redirects == 0 or not location.some?

    dropped(result)
    hop = try Redirect.next(target, hop, got.response.status, location.unwrap!, client.proxied)
    redirects = redirects + 1
  end

  Exchange.failure("more than #{client.max_redirects} redirects", "redirect.too_many")
end

def decoded(client: Client, response: Exchange.Response) -> Result[Exchange.Response]
  return ok(response) if not client.decompress

  Encoding.decoded(response, client.max_body_bytes)
end

def system_lookup(host: String) -> Result[List[String]] = DNS.lookup(host)

def argument[T](text: String) -> Result[T] = error("http_client: #{text}", kind: "argument")

# The public fields of a client, which `client.with(...)` may change.
def valid(client: Client) -> Result[Void]
  if client.connect_timeout_ms < 1 or client.read_timeout_ms < 1 or client.timeout_ms < 1
    return argument("connect_timeout_ms, read_timeout_ms and timeout_ms must be at least 1")
  end

  return argument("body_idle_ms must be 0 (no limit) or more") if idle_limit(client) < 0

  longest = [
    client.connect_timeout_ms,
    client.read_timeout_ms,
    idle_limit(client),
    client.timeout_ms,
    client.max_retry_delay_ms,
  ].max

  return argument("a time setting is over #{MAX_MS} ms") if longest.unwrap! > MAX_MS

  return argument("max_body_bytes must be at least 1") if client.max_body_bytes < 1
  if client.max_retries < 0 or client.retry_delay_ms < 0 or client.max_retry_delay_ms < 0 or client.max_redirects < 0
    return argument("max_retries, retry_delay_ms, max_retry_delay_ms and max_redirects must be at least 0")
  end

  return ok() if client.base_url.empty?

  _ = try Url.resolve("", client.base_url)
  ok()
end

# Between half the backoff and all of it, so that clients that failed together do not come back together.
def jitter(backoff_ms: Int) -> Int = Random.int(backoff_ms / 2, backoff_ms)

# The longest a body may stay silent: its own budget, or the read timeout when the client names none, which is what
# every client had before the head and the body were separate.
def idle_limit(client: Client) -> Int = client.body_idle_ms.unwrap_or(client.read_timeout_ms)

def responded(result: Result[Got]) -> Result[Exchange.Response]
  case result
    ok(got) -> ok(got.response)
    error(e) -> error(e)
  end
end

# A stream that is not given to the caller is cancelled, which ends its request and gives its connection up rather than
# leaving it to the next read: the response is thrown away anyway.
def dropped(result: Result[Got]) -> Void
  case result
    ok(got) if got.stream.some? -> cancel(got.stream.unwrap!)
    _ -> nil
  end
end

# Whether a response of a streamed call is read whole all the same, from its head: one that may be redirected or
# retried.
def kept_whole?(client: Client, hop: Hop, tries: Int, head: Exchange.Response) -> Bool
  return true if client.max_redirects > 0 and Redirect.location(head).some?

  policy = Retry.Policy(
    max_retries: client.max_retries,
    delay_ms: client.retry_delay_ms,
    max_delay_ms: client.max_retry_delay_ms,
  )

  Retry.wait_ms(policy, hop.method, ok(head), tries, Time.now_ms(), &jitter).some?
end

# Reads the body into events until its end, then closes `out`, or ends `out` with the error that cut it short. The
# client waits for this task when it closes.
def relay(stream: Stream, out: Channel[Result[Sse.Event]], max_bytes: Int) -> Void
  case relayed(stream, out, max_bytes)
    ok(_) -> out.close
    error(e) -> Exchange.cut(out, e)
  end

  stream.body.close
end

# Gives an event once the reader took the last one, and reads the body while it holds few events, so that each event
# has `read_timeout_ms` from when it is given, and a reader that closed `out` closes the body at once, even when the
# body brings no events.
def relayed(stream: Stream, out: Channel[Result[Sse.Event]], max_bytes: Int) -> Result[Void]
  try Pools.watch(stream.pools, Task.current, "")
  now = Time.monotonic_ms()
  state = Relaying(parser: Sse.parser(), pending: [], given_at: now, heard_at: now, ended: false)
  while not (state.ended and state.pending.empty?) and not out.closed?
    state = try relay_step(stream, out, state, max_bytes)
  end

  ok()
end

def relay_step(stream: Stream, out: Channel[Result[Sse.Event]], state: Relaying, max_bytes: Int) -> Result[Relaying]
  return Exchange.failure("the client is closed", "closed") if stream.pools.stopping.closed?

  now = Time.monotonic_ms()
  if not state.pending.empty?
    if out.empty?
      _ = out.send(ok(state.pending[0]), 0)
      return ok(state.with(pending: state.pending.drop(1), given_at: now))
    end

    if now - state.given_at >= stream.read_timeout_ms
      return Exchange.failure("the reader took no event for #{stream.read_timeout_ms} ms", "timeout.read")
    end
  end

  if state.ended or state.pending.size >= EVENTS
    Task.sleep(RELAY_POLL_MS)
    return ok(state)
  end

  wait_ms = RELAY_POLL_MS
  if state.pending.empty?
    wait_ms = RELAY_IDLE_MS
  end

  case stream.body.recv(wait_ms)
    ok(item) ->
      fed = try Sse.feed(state.parser, try item, max_bytes)
      ok(state.with(parser: fed.parser, pending: state.pending + fed.events, heard_at: now))
    error(_) if stream.body.closed? and stream.body.empty? -> ok(state.with(ended: true))
    error(_) if body_stalled?(stream, now, state) ->
      Exchange.failure("no piece of the body came within #{stream.body_idle_ms} ms", "timeout.read")
    error(_) -> ok(state)
  end
end

# A body with no idle limit may stay silent for ever: the end of the client, the reader of the events or `cancel` ends
# it.
def body_stalled?(stream: Stream, now: Int, state: Relaying) -> Bool
  return false if stream.body_idle_ms == 0

  now - state.heard_at >= stream.body_idle_ms + RELAY_SLACK_MS
end

# One try of the hop, within what is left of the call.
def once(client: Client, hop: Hop, deadline: Int, streamed: Bool, tries: Int) -> Result[Got]
  return timed_out(client) if deadline - Time.monotonic_ms() < 1

  pool = try Pools.pool_for(client.pools, hop.target.origin, client.timeout_ms)
  left = deadline - Time.monotonic_ms()
  return timed_out(client) if left < 1

  call = Exchange.Call(
    method: hop.method,
    target: hop.target,
    headers: hop.headers,
    body: hop.body,
    connect_timeout_ms: client.connect_timeout_ms,
    read_timeout_ms: client.read_timeout_ms,
    body_idle_ms: idle_limit(client),
    deadline: deadline,
    max_body_bytes: client.max_body_bytes,
    streaming: none,
  )

  arrivals: Channel[Exchange.Arrival] = Channel.new(2)
  if streamed
    whole = ->(head) { kept_whole?(client, hop, tries, head) }
    streaming = Exchange.Streaming(whole: whole, arrivals: arrivals, stopping: client.pools.stopping)
    call = call.with(streaming: some(streaming))
  end

  # A task of its own, so that `timeout_ms` can cancel the request wherever it is; the pool then ends its connection.
  # The task of a streamed response goes on after its head, until the end of its body, and the client waits for it
  # when it closes.
  running = Task.spawn do borrowed(client, pool, call, streamed) end

  Task.monitor(running, arrivals) do |_down| Exchange.Arrival.Over end
  case arrivals.recv(left)
    ok(arrival) -> arrived(client, running, arrival)
    error(_) ->
      Task.cancel(running)
      _ = Task.await(running, CANCEL_MS)
      timed_out(client)
  end
end

def borrowed(client: Client, pool: Pools.OriginPool, call: Exchange.Call, streamed: Bool) -> Result[Exchange.Response]
  if streamed
    try Pools.watch(client.pools, Task.current, call.target.origin)
  end

  Pool.with(pool) do |link| Exchange.run(link, call) end
end

def arrived(client: Client, running: Task[Result[Exchange.Response]], arrival: Exchange.Arrival) -> Result[Got]
  case arrival
    Exchange.Arrival.Head(head) ->
      response = Exchange.Response(status: head.status, headers: head.headers, body: NO_BODY, url: head.url)
      streamed = Stream(
        status: head.status,
        headers: head.headers,
        url: head.url,
        body: head.body,
        read_timeout_ms: client.read_timeout_ms,
        body_idle_ms: idle_limit(client),
        pools: client.pools,
        relayed: head.relayed,
        relay_down: head.relay_down,
        ended: head.ended,
        worker: some(running),
      )

      ok(Got(response: response, stream: some(streamed)))
    Exchange.Arrival.Over ->
      case Task.await(running, 1)
        Await.Done(result) -> ok(Got(response: try pool_failure(result), stream: none))
        Await.TimedOut -> timed_out(client)
      end
  end
end

def timed_out[T](client: Client) -> Result[T]
  Exchange.failure("the request timed out after #{client.timeout_ms} ms", "timeout.request")
end

# The headers of the call replace those of the client with the same name; the case of a name does not matter.
def merge(base: List[HTTP.Header], extra: List[HTTP.Header]) -> List[HTTP.Header]
  names = extra.map { |header| header.name.downcase }
  kept = base.select { |header| not names.include?(header.name.downcase) }
  kept + extra
end

# The pool's own errors, in the client's kinds.
def pool_failure(result: Result[Exchange.Response]) -> Result[Exchange.Response]
  case result
    error(e) if e.is_a?("pool.timeout.checkout") -> Exchange.failure("no connection was free", "timeout.pool", some(e))
    error(e) if e.is_a?("pool.closed") -> Exchange.failure("the client is closed", "closed", some(e))
    error(e) if e.is_a?("pool.full") ->
      Exchange.failure("too many requests wait for a connection", "pool_full", some(e))
    error(e) if e.is_a?("task") -> Exchange.failure("the request crashed", "crashed", some(e))
    _ -> result
  end
end

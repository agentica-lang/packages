## An HTTP client with a pool of keep-alive connections per origin, in the spirit of Elixir's Req: make a `Client`
## once with `new`, send requests with `get`, `post` and the others, and `close` it at the end.
##
## Each origin (scheme, host and port) has a pool of `pool_size` connections, made when a request first needs one. A
## request waits at most `pool_timeout_ms` for a free connection, at most `connect_timeout_ms` to connect, at most
## `read_timeout_ms` for each read, and at most `timeout_ms` for the whole call. A connection is kept for the next
## request only when its response was read to its end and the server did not close it. An idempotent request goes
## again after a transient error or status (`src/retry.agc`), a redirect is followed (`src/redirect.agc`), and a gzip
## or deflate body is decoded (`src/encoding.agc`). The request steps of the client change each request before it
## goes, and its response steps change each response it gives (`Request`).

import Dial from "src/dial"
import Encoding from "src/encoding"
import Exchange from "src/exchange"
import HTTP from "std/http"
import Pool from "pkg/pool/pool"
import Pools from "src/pools"
import Redirect from "src/redirect"
import {Hop} from "src/redirect"
import Retry from "src/retry"
import Sse from "src/sse"
import URI from "std/uri"
import Url from "src/url"

export Exchange.Response
export Exchange.Stream
export Sse.Event

## A request as the request steps see it: the method, the whole URL with its query, the headers and the body.
struct Request
  method: String
  url: String
  headers: List[HTTP.Header]
  body: Bytes
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
end

## Makes a client. `base_url` is joined to the URL of a request that is a path (`/todos`); the pool settings are
## `pool_size` connections per origin, `pool_timeout_ms` of wait for one, and `idle_ms` after which an unused one is
## closed. An idempotent request is tried again at most `max_retries` times in all, after `retry_delay_ms` doubled on
## each try (at most `max_retry_delay_ms`); at most `max_redirects` redirects are followed (0 gives the redirect back).
## `timeout_ms` bounds the whole call, its tries, waits and redirects included. With a `resolver` (one such as
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
) -> Result[Client]
  if pool_timeout_ms < 1 or idle_ms < 1 or pool_timeout_ms > MAX_MS or idle_ms > MAX_MS
    return argument("pool_timeout_ms and idle_ms must be 1 to #{MAX_MS}")
  end

  return argument("pool_size must be at least 1") if pool_size < 1
  return argument("dns_cache_ms must be 0 to #{MAX_MS}") if dns_cache_ms < 0 or dns_cache_ms > MAX_MS
  if not proxy.empty? and (resolver.some? or public_only)
    return argument("a proxy resolves the host itself: give no resolver and no public_only with it")
  end

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
  )

  client = Client(
    base_url: base_url,
    headers: headers,
    params: params,
    connect_timeout_ms: connect_timeout_ms,
    read_timeout_ms: read_timeout_ms,
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
## compression and decodes none, and runs no response steps. A response that is retried or redirected is read whole
## and dropped, as for `request`; so is one that cannot go again for lack of time, which then comes as one piece.
## `timeout_ms` bounds the call up to the head; after it, each piece has `read_timeout_ms` to come, and the reader as
## long to take it, else the stream ends. Read `body` to its end, or close it, so that its connection goes back to the
## pool.
def stream(
  client: Client,
  method: String,
  url: String,
  body: Optional[Bytes] = none,
  json: Optional[JSON.Value] = none,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Stream]
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
      ok(Exchange.Stream(status: response.status, headers: response.headers, url: response.url, body: pieces))
  end
end

## The server-sent events of `stream` (`text/event-stream`), read by a task of their own: `ok(event)` for each, or one
## `error` when the body fails or an event is over `max_event_bytes` (`http_client.too_large`); the channel closes at
## the end of the body. Closing it early closes the body. The client does not reconnect: a reader that wants to goes
## again with the `last-event-id` header, from the `id` of the last event.
def events(stream: Exchange.Stream, max_event_bytes: Int = 1_048_576) -> Channel[Result[Sse.Event]]
  out: Channel[Result[Sse.Event]] = Channel.new(EVENTS)
  Task.spawn do relay(stream.body, out, max_event_bytes) end
  out
end

## A `GET` request whose body comes as a stream of server-sent events, with `accept: text/event-stream` unless
## `headers` name another.
def get_events(
  client: Client,
  url: String,
  params: List[URI.Pair] = [],
  headers: List[HTTP.Header] = [],
  max_event_bytes: Int = 1_048_576,
) -> Result[Channel[Result[Sse.Event]]]
  streamed = try stream(client, "GET", url, params: params, headers: merge([EVENT_STREAM], headers))
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
# The events that wait for the reader, and how long the relay waits for a piece and for the reader. Each piece comes
# within the `read_timeout_ms` of the client, or the body ends, so these waits only bound a reader that forgets the
# channel.
EVENTS = 16
RELAY_MS = 3_600_000

# What a try gives: the response, whole, or its head and the stream of its body.
struct Got
  response: Exchange.Response
  stream: Optional[Exchange.Stream]
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

  longest = [client.connect_timeout_ms, client.read_timeout_ms, client.timeout_ms, client.max_retry_delay_ms].max
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

def responded(result: Result[Got]) -> Result[Exchange.Response]
  case result
    ok(got) -> ok(got.response)
    error(e) -> error(e)
  end
end

# A stream that is not given to the caller is closed, which ends its request.
def dropped(result: Result[Got]) -> Void
  case result
    ok(got) if got.stream.some? -> got.stream.unwrap!.body.close
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

# Reads the pieces of `body` into events until its end, or until the reader closes `out`.
def relay(body: Channel[Result[Bytes]], out: Channel[Result[Sse.Event]], max_bytes: Int) -> Result[Void]
  parser = Sse.parser()
  piece = body.recv(RELAY_MS)
  while piece.ok? and not out.closed?
    case piece.unwrap!
      ok(bytes) ->
        case Sse.feed(parser, bytes, max_bytes)
          ok(fed) ->
            parser = fed.parser
            for event in fed.events
              _ = out.send(ok(event), RELAY_MS)
            end

          error(e) ->
            _ = out.send(error(e), RELAY_MS)
            out.close
        end

      error(e) ->
        _ = out.send(error(e), RELAY_MS)
        out.close
    end

    piece = body.recv(RELAY_MS)
  end

  body.close
  out.close
  ok()
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
    deadline: deadline,
    max_body_bytes: client.max_body_bytes,
    streaming: none,
  )

  arrivals: Channel[Exchange.Arrival] = Channel.new(2)
  if streamed
    whole = ->(head) { kept_whole?(client, hop, tries, head) }
    call = call.with(streaming: some(Exchange.Streaming(whole: whole, arrivals: arrivals)))
  end

  # A task of its own, so that `timeout_ms` can cancel the request wherever it is; the pool then ends its connection.
  # The task of a streamed response goes on after its head, until the end of its body.
  running = Task.spawn do Pool.with(pool) do |link| Exchange.run(link, call) end end
  Task.monitor(running, arrivals) do |_down| Exchange.Arrival.Over end
  case arrivals.recv(left)
    ok(arrival) -> arrived(client, running, arrival)
    error(_) ->
      Task.cancel(running)
      _ = Task.await(running, CANCEL_MS)
      timed_out(client)
  end
end

def arrived(client: Client, running: Task[Result[Exchange.Response]], arrival: Exchange.Arrival) -> Result[Got]
  case arrival
    Exchange.Arrival.Head(head) ->
      response = Exchange.Response(status: head.status, headers: head.headers, body: NO_BODY, url: head.url)
      ok(Got(response: response, stream: some(head)))
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

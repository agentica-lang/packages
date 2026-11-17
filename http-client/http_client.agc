## An HTTP client with a pool of keep-alive connections per origin, in the spirit of Elixir's Req: make a `Client`
## once with `new`, send requests with `get`, `post` and the others, and `close` it at the end.
##
## Each origin (scheme, host and port) has a pool of `pool_size` connections, made when a request first needs one. A
## request waits at most `pool_timeout_ms` for a free connection, at most `connect_timeout_ms` to connect, at most
## `read_timeout_ms` for each read, and at most `timeout_ms` for the whole call. A connection is kept for the next
## request only when its response was read to its end and the server did not close it. An idempotent request goes
## again after a transient error or status (`src/retry.agc`), and a redirect is followed (`src/redirect.agc`).

import Dial from "src/dial"
import Exchange from "src/exchange"
import HTTP from "std/http"
import Pool from "pkg/pool/pool"
import Pools from "src/pools"
import Redirect from "src/redirect"
import {Hop} from "src/redirect"
import Retry from "src/retry"
import Url from "src/url"

export Exchange.Response

## A client. The public fields apply to each request, and `client.with(...)` gives a client with other values that
## shares the pools: `client.with(read_timeout_ms: 500)`. `headers` go with every request, under the headers of the
## call.
struct Client
  base_url: String
  headers: List[HTTP.Header]
  connect_timeout_ms: Int
  read_timeout_ms: Int
  timeout_ms: Int
  max_body_bytes: Int
  max_retries: Int
  retry_delay_ms: Int
  max_retry_delay_ms: Int
  max_redirects: Int

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
## address the connection goes to. With neither, std/http resolves the host and `dns_cache_ms` has no effect. `proxy` (`http://host:port`) and
## `tls` (a client `TLS.Context`, the system trust when none) are those of std/http's `ClientOptions`; a proxy
## resolves the host itself, so it is refused with a `resolver` or `public_only`. Make the client in a task that lives
## as long as it does, such as `main`.
def new(
  base_url: String = "",
  headers: List[HTTP.Header] = [],
  connect_timeout_ms: Int = 10_000,
  read_timeout_ms: Int = 30_000,
  timeout_ms: Int = 60_000,
  max_body_bytes: Int = 16_777_216,
  max_retries: Int = 3,
  retry_delay_ms: Int = 500,
  max_retry_delay_ms: Int = 30_000,
  max_redirects: Int = 10,
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
    connect_timeout_ms: connect_timeout_ms,
    read_timeout_ms: read_timeout_ms,
    timeout_ms: timeout_ms,
    max_body_bytes: max_body_bytes,
    max_retries: max_retries,
    retry_delay_ms: retry_delay_ms,
    max_retry_delay_ms: max_retry_delay_ms,
    max_redirects: max_redirects,
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

## Sends a request and gives the whole response, after its retries and redirects. A 4xx or 5xx is a response, not an
## error. An error has a kind: `http_client.timeout.pool`, `.connect`, `.read` or `.request` (all
## `http_client.timeout`), `http_client.pool_full` (1000 requests wait already), `http_client.network`,
## `http_client.too_large` (a body over `max_body_bytes`), `http_client.redirect.too_many` (over `max_redirects`),
## `http_client.redirect.location` (a `Location` that cannot be followed), `http_client.closed`,
## `http_client.crashed` (a bug: the request's task crashed) or `argument` (a bad URL, method or header, or a bad
## client field).
def request(
  client: Client,
  method: String,
  url: String,
  body: Bytes,
  headers: List[HTTP.Header] = [],
) -> Result[Exchange.Response]
  try valid(client)
  target = try Url.resolve(client.base_url, url)
  deadline = Time.monotonic_ms() + client.timeout_ms
  policy = Retry.Policy(
    max_retries: client.max_retries,
    delay_ms: client.retry_delay_ms,
    max_delay_ms: client.max_retry_delay_ms,
  )

  hop = Hop(method: method, target: target, headers: merge(client.headers, headers), body: body)
  tries = 0
  redirects = 0
  while redirects <= client.max_redirects
    result = once(client, hop, deadline)
    case Retry.wait_ms(policy, hop.method, result, tries, Time.now_ms(), &jitter)
      some(ms) if Time.monotonic_ms() + ms < deadline ->
        Task.sleep(ms)
        tries = tries + 1
        next
      _ -> nil
    end

    response = try result
    location = Redirect.location(response)
    return ok(response) if client.max_redirects == 0 or not location.some?

    hop = try Redirect.next(target, hop, response.status, location.unwrap!, client.proxied)
    redirects = redirects + 1
  end

  Exchange.failure("more than #{client.max_redirects} redirects", "redirect.too_many")
end

## A `GET` request.
def get(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "GET", url, NO_BODY, headers)
end

## A `HEAD` request: the response has no body.
def head(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "HEAD", url, NO_BODY, headers)
end

## A `DELETE` request.
def delete(client: Client, url: String, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "DELETE", url, NO_BODY, headers)
end

## A `POST` request with `body`.
def post(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "POST", url, body, headers)
end

## A `PUT` request with `body`.
def put(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "PUT", url, body, headers)
end

## A `PATCH` request with `body`.
def patch(client: Client, url: String, body: Bytes, headers: List[HTTP.Header] = []) -> Result[Exchange.Response]
  request(client, "PATCH", url, body, headers)
end

## Closes the pools: the requests in flight have `drain_ms` to end, then their connections close. A request after the
## close is an `http_client.closed` error.
def close(client: Client, drain_ms: Int = 5_000) -> Void
  Pools.close(client.pools, drain_ms)
end

private

NO_BODY = "".bytes
# The largest request body that std/http sends.
MAX_REQUEST_BODY = 67_108_864
# The largest time setting: a year, far from an overflow when it is added to a clock.
MAX_MS = 31_536_000_000
# The health tick of each pool checks its idle connections and closes those unused for `idle_ms`.
HEALTH_MS = 5_000
# How long a try that ran out of time has to end once cancelled.
CANCEL_MS = 1_000

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

# One try of the hop, within what is left of the call.
def once(client: Client, hop: Hop, deadline: Int) -> Result[Exchange.Response]
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
  )

  # A task of its own, so that `timeout_ms` can cancel the request wherever it is; the pool then ends its connection.
  running = Task.spawn do Pool.with(pool) do |link| Exchange.run(link, call) end end
  case Task.await(running, left)
    Await.Done(result) -> pool_failure(result)
    Await.TimedOut ->
      Task.cancel(running)
      _ = Task.await(running, CANCEL_MS)
      timed_out(client)
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

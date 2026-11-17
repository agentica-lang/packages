## How a link reaches its origin. A client with neither `resolver` nor `public_only` connects through std/http as it
## is, which resolves the host itself. One with either takes the dial path: the host resolved by the client's resolver
## (through its DNS cache), the addresses kept by the `public_only` filter, then a connection to one of them, tried in
## order.
##
## The connection goes to the very address that was checked, so the filter holds against a DNS answer that changes
## (rebinding): `HTTP.start(url, options.with(connect_to: address))`. std/http connects to the address and uses the
## host of the URL for `Host`, the TLS server name and the certificate check.
##
## A host that is an IP literal is not resolved: std/http connects to it as it is, after the filter. With a `proxy`
## the proxy reaches the host, so the client refuses a resolver or `public_only` together with one.

import Address from "address"
import HTTP from "std/http"
import Url from "url"

## How a client resolves and filters: whether it takes the dial path at all (`own`), the resolver, the cache it
## shares between its links (`cache_ms` 0 for none), and whether only public addresses may be reached.
struct Dialer
  own: Bool
  resolver: Fn[String, Result[List[String]]]
  cache: ATS[String, Resolved]
  cache_ms: Int
  public_only: Bool
end

## The addresses of a host and the monotonic time at which they expire from the cache.
struct Resolved
  addresses: List[String]
  expires_at: Int
end

## Opens a connection to the origin `url` (`scheme://host:port`) within `wait_ms`. A host that does not resolve is an
## `http_client.dns` error, and one with no address the filter keeps an `http_client.address_denied` error; the
## errors of the connect itself are std/http's.
def connect(dialer: Dialer, url: String, options: HTTP.ClientOptions, wait_ms: Int) -> Result[HTTP.Connection]
  return HTTP.start(url, limited(options, wait_ms)) if not dialer.own or not options.proxy.empty?

  target = try Url.resolve("", url)
  host = Address.unbracketed(target.host)
  if Address.literal?(target.host)
    try allowed(dialer, host, [host])
    return HTTP.start(url, limited(options, wait_ms))
  end

  deadline = Time.monotonic_ms() + wait_ms
  addresses = try allowed(dialer, host, try resolved(dialer, host, deadline))
  last: Result[HTTP.Connection] = timed_out()
  for at in 0..(addresses.size - 1)
    left = deadline - Time.monotonic_ms()
    return timed_out() if left < 1

    # Each address gets its share of the time left, so that one that never answers leaves time for the next.
    share = [left / (addresses.size - at), 1].max.unwrap!
    last = reach(url, addresses[at], limited(options, share))
    return last if last.ok?
  end

  last
end

private

# Past this many hosts the cache starts again, so that a client that meets many names keeps a bounded table.
MAX_CACHED = 1_024
# How long a resolver that was cancelled has to end.
CANCEL_MS = 1_000

# The options of a connect that takes at most `ms`: the whole call and the connect (std/http's `connect_timeout_ms` is
# 10 s unless set).
def limited(options: HTTP.ClientOptions, ms: Int) -> HTTP.ClientOptions
  options.with(timeout_ms: ms, connect_timeout_ms: ms)
end

def timed_out[T]() -> Result[T] = error("network: operation timed out", kind: "net.timeout")

# The resolver runs in a task of its own, so that one that never answers costs the connect its time, not the link its
# task: past the deadline it is cancelled, and the connect is a timeout.
def asked(dialer: Dialer, host: String, deadline: Int) -> Result[List[String]]
  left = deadline - Time.monotonic_ms()
  return timed_out() if left < 1

  asking = Task.spawn do dialer.resolver.call(host) end
  case Task.await(asking, left)
    Await.Done(answer) -> answer
    Await.TimedOut ->
      Task.cancel(asking)
      _ = Task.await(asking, CANCEL_MS)
      timed_out()
  end
end

def resolved(dialer: Dialer, host: String, deadline: Int) -> Result[List[String]]
  key = host.downcase
  now = Time.monotonic_ms()
  case dialer.cache.get(key)
    ok(cached) if cached.expires_at > now -> return ok(cached.addresses)
    _ -> nil
  end

  addresses: List[String] = []
  case asked(dialer, host, deadline)
    ok(found) ->
      addresses = found.select { |address| Address.parse(address).some? }.map { |address| Address.unmapped(address) }
    error(e) if e.is_a?("net.timeout") -> return error(e)
    error(e) -> return error("http_client: cannot resolve #{host}: #{e.message}", kind: "http_client.dns", cause: e)
  end

  return error("http_client: #{host} has no IP address", kind: "http_client.dns") if addresses.empty?

  if dialer.cache_ms > 0
    if dialer.cache.size >= MAX_CACHED
      dialer.cache.clear
    end

    dialer.cache.put(key, Resolved(addresses: addresses, expires_at: now + dialer.cache_ms))
  end

  ok(addresses)
end

def allowed(dialer: Dialer, host: String, addresses: List[String]) -> Result[List[String]]
  return ok(addresses) if not dialer.public_only

  kept = addresses.select { |address| Address.public?(address) }
  return error("http_client: #{host} has no public address", kind: "http_client.address_denied") if kept.empty?

  ok(kept)
end

# A connection to `address` that std/http uses as one to `host`: `connect_to` goes there, while TLS checks the host
# of the
# URL and `Host` names it.
def reach(url: String, address: String, options: HTTP.ClientOptions) -> Result[HTTP.Connection]
  HTTP.start(url, options.with(connect_to: address))
end

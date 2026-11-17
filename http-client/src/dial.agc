## How a link reaches its origin. A client with neither `resolver` nor `public_only` connects through std/http as it
## is, which resolves the host itself. One with either takes the dial path: the host resolved by the client's resolver
## (through its DNS cache), the addresses kept by the `public_only` filter, then a connection to one of them, tried in
## order.
##
## The connection goes to the very address that was checked, so the filter holds against a DNS answer that changes
## (rebinding). Until std/http has `connect_to` (agentica#1556), `connect` opens a plain connection to the address
## with `HTTP.start`, upgrades it to TLS for `https` with the URL host as the server name (SNI and certificate check),
## and sets the URL host on the connection, which std/http writes in `Host`: it relies on the `host`, `socket` and
## `scheme` fields of std's `Connection`, which is why the dial path is opt-in. With `connect_to` this becomes
## `HTTP.start(url, options.with(connect_to: address))`, and the rest of the module stays; the dial path may then be
## the default for every client.
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
  return HTTP.start(url, options.with(timeout_ms: wait_ms)) if not dialer.own or not options.proxy.empty?

  target = try Url.resolve("", url)
  host = Address.unbracketed(target.host)
  if Address.literal?(target.host)
    try allowed(dialer, host, [host])
    return HTTP.start(url, options.with(timeout_ms: wait_ms))
  end

  deadline = Time.monotonic_ms() + wait_ms
  addresses = try allowed(dialer, host, try resolved(dialer, host))
  last: Result[HTTP.Connection] = error("network: no address", kind: "net.failed")
  for address in addresses
    left = deadline - Time.monotonic_ms()
    return error("network: operation timed out", kind: "net.timeout") if left < 1

    last = reach(target, host, address, options.with(timeout_ms: left))
    return last if last.ok?
  end

  last
end

private

# Past this many hosts the cache starts again, so that a client that meets many names keeps a bounded table.
MAX_CACHED = 1_024

def resolved(dialer: Dialer, host: String) -> Result[List[String]]
  key = host.downcase
  now = Time.monotonic_ms()
  case dialer.cache.get(key)
    ok(cached) if cached.expires_at > now -> return ok(cached.addresses)
    _ -> nil
  end

  addresses: List[String] = []
  case dialer.resolver.call(host)
    ok(found) -> addresses = found.select { |address| Address.parse(address).some? }
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

# A connection to `address` that std/http uses as one to `host`: TLS checks `host`, and `Host` names it.
def reach(target: Url.Target, host: String, address: String, options: HTTP.ClientOptions) -> Result[HTTP.Connection]
  authority = address
  if address.include?(":")
    authority = "[#{address}]"
  end

  conn = try HTTP.start("http://#{authority}:#{target.port}", options.with(tls: none))
  return ok(conn.with(host: host)) if target.scheme == "http"

  case secured(conn, host, options)
    ok(socket) -> ok(conn.with(socket: socket, scheme: target.scheme, host: host))
    error(e) ->
      HTTP.finish(conn)
      error(e)
  end
end

# The TLS socket over the connection, with the context of the options or one with the system trust, as std/http
# makes. It speaks HTTP/1.1 only, as std/http does.
def secured(conn: HTTP.Connection, host: String, options: HTTP.ClientOptions) -> Result[TCP.Socket]
  context = case options.tls
    some(given) -> given
    none -> try TLS.client_context(TLS.ClientOptions())
  end

  socket = try TLS.upgrade(conn.socket, context, host, options.timeout_ms)
  protocol = TLS.alpn(socket)
  if protocol != "" and protocol != "http/1.1"
    TCP.close(socket)
    return error("http_client: the server picked #{protocol}, not HTTP/1.1", kind: "net.tls")
  end

  ok(socket)
end

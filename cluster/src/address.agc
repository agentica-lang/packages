## The address of a peer, `host:port`, and the rule for plain TCP: only on this machine.

## A `host:port` read apart. An IPv6 host is written in brackets, `[::1]:4000`.
struct Endpoint
  host: String
  port: Int
end

## Reads `host:port`. The port is 1 to 65535.
def parse(text: String) -> Result[Endpoint]
  parts = text.split(":")
  return bad(text) if parts.size < 2

  port_text = parts.last
  port = port_text.to_i.unwrap_or(0)
  host = unbracket(text.slice(0, text.length - port_text.length - 1))
  return bad(text) if host.empty? or port < 1 or port > MAX_PORT or port_text.length > 5

  ok(Endpoint(host: host, port: port))
end

## Whether a host is this machine: `localhost`, `::1` or an IPv4 address of `127.0.0.0/8`. Plain TCP is only allowed
## there, since a frame after the handshake has no integrity or secrecy.
def loopback?(host: String) -> Bool
  return true if host == "localhost" or host == "::1"

  parts = host.split(".")
  return false if parts.size != 4 or parts[0] != "127"

  parts.all? { |part| octet?(part) }
end

private

MAX_PORT = 65_535
MAX_OCTET = 255

def bad[T](text: String) -> Result[T] = error("cluster: #{text} is not host:port", kind: "cluster.argument")

def unbracket(host: String) -> String
  return host.slice(1, host.length - 2) if host.start_with?("[") and host.end_with?("]")

  host
end

def octet?(part: String) -> Bool
  case part.to_i
    ok(n) -> n >= 0 and n <= MAX_OCTET and not part.empty? and part.length <= 3
    error(_) -> false
  end
end

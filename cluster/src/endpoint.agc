## The address of a peer, `host:port`, and the rule for plain TCP: only on this machine.

import Names from "names"
import Types from "types"

## The address as a key of the dials: `host:port`.
def key(endpoint: Types.Endpoint) -> String = "#{endpoint.host}:#{endpoint.port}"

## Reads `host:port` or `name@host:port`. The port is 1 to 65535, and a name has the form of a node name.
def parse(text: String) -> Result[Types.Endpoint]
  at = text.split("@")
  return bad(text) if at.size > 2

  return parse_host(text, "") if at.size == 1

  return bad(text) if not Names.node_name?(at[0])

  parse_host(at[1], at[0])
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
DIGITS = "0".code.."9".code

def parse_host(text: String, node: String) -> Result[Types.Endpoint]
  parts = text.split(":")
  return bad(text) if parts.size < 2

  port_text = parts.last
  port = port_text.to_i.unwrap_or(0)
  host = unbracket(text.slice(0, text.length - port_text.length - 1))
  return bad(text) if host.empty? or port < 1 or port > MAX_PORT or port_text.length > 5

  ok(Types.Endpoint(host: host, port: port, node: node))
end

def bad[T](text: String) -> Result[T] = error("cluster: #{text} is not host:port", kind: "cluster.argument")

def unbracket(host: String) -> String
  return host.slice(1, host.length - 2) if host.start_with?("[") and host.end_with?("]")

  host
end

def octet?(part: String) -> Bool
  return false if part.empty? or part.length > 3
  return false if not part.bytes.to_a.all? { |b| DIGITS.include?(b) }

  part.to_i.unwrap_or(MAX_OCTET + 1) <= MAX_OCTET
end

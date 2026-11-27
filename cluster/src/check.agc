## The checks of the options of a node, before anything opens: the names, the cookie, the limits, and plain TCP only on
## this machine.

import Endpoint from "endpoint"
import Handshake from "handshake"
import Names from "names"
import Types from "types"

## Checks the options and gives back the endpoints of `peers`.
def check(options: Types.Options) -> Result[List[Types.Endpoint]]
  return refuse("the name of the node is not valid") if not Names.node_name?(options.name)

  try Handshake.cookie(options.cookie)
  return refuse("connect_ms is 1 to #{MAX_MS}") if options.connect_ms < 1 or options.connect_ms > MAX_MS
  return refuse("max_pending is 1 to #{MAX_PENDING}") if options.max_pending < 1 or options.max_pending > MAX_PENDING
  if frame_limit_bad?(options)
    return refuse("max_frame_bytes is #{Types.PRE_AUTH_MAX_FRAME_BYTES} to #{Types.MAX_FRAME_BYTES}")
  end

  return refuse("the port is 0 to 65535") if options.port < 0 or options.port > MAX_PORT
  try plain_allowed(options.host, options.insecure_plaintext)
  endpoints: List[Types.Endpoint] = []
  seen: Set[String] = Set.new([])
  for text in options.peers
    parsed = try endpoint(text, options.insecure_plaintext)
    if not seen.include?(Endpoint.key(parsed))
      seen = seen.add(Endpoint.key(parsed))
      endpoints = endpoints.push(parsed)
    end
  end

  ok(endpoints)
end

## Reads an address of a peer, and checks that plain TCP may reach it.
def endpoint(text: String, insecure_plaintext: Bool) -> Result[Types.Endpoint]
  parsed = try Endpoint.parse(text)
  try plain_allowed(parsed.host, insecure_plaintext)
  ok(parsed)
end

private

# So that adding a time to the clock cannot overflow, and a handshake cannot last longer than ten minutes.
MAX_MS = 600_000
MAX_PENDING = 100_000
MAX_PORT = 65_535

def refuse[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.ARGUMENT)

def frame_limit_bad?(options: Types.Options) -> Bool
  options.max_frame_bytes < Types.PRE_AUTH_MAX_FRAME_BYTES or options.max_frame_bytes > Types.MAX_FRAME_BYTES
end

# Without TLS, the frames after the handshake have no secrecy or integrity: plain TCP stays on this machine unless the
# options say that the network is trusted.
def plain_allowed(host: String, insecure_plaintext: Bool) -> Result[Void]
  return ok() if insecure_plaintext or Endpoint.loopback?(host)

  refuse("plain TCP is only for this machine; set insecure_plaintext for a trusted network")
end

## The checks of the options of a node, before anything opens: the names, the cookie, the limits, and plain TCP only on
## this machine.

import Address from "address"
import Handshake from "handshake"
import Names from "names"
import Types from "types"

## The most that a time or a size option may be, so that adding it to a clock cannot overflow.
MAX_MS = 86_400_000

## Checks the options and gives back the endpoints of `peers`.
def check(options: Types.Options) -> Result[List[Types.Endpoint]]
  return refuse("the name of the node is not valid") if not Names.node_name?(options.name)

  try Handshake.cookie(options.cookie)
  return refuse("connect_ms is 1 to #{MAX_MS}") if options.connect_ms < 1 or options.connect_ms > MAX_MS
  return refuse("max_frame_bytes is #{Types.PRE_AUTH_MAX_FRAME_BYTES} to #{MAX_FRAME}") if frame_limit_bad?(options)
  return refuse("the port is 0 to 65535") if options.port < 0 or options.port > MAX_PORT
  try plain_allowed(options.host, options.insecure_plaintext)
  endpoints: List[Types.Endpoint] = []
  for text in options.peers
    endpoints = endpoints.push(try endpoint(text, options.insecure_plaintext))
  end

  ok(endpoints)
end

## Reads an address of a peer, and checks that plain TCP may reach it.
def endpoint(text: String, insecure_plaintext: Bool) -> Result[Types.Endpoint]
  parsed = try Address.parse(text)
  try plain_allowed(parsed.host, insecure_plaintext)
  ok(parsed)
end

private

MAX_PORT = 65_535
MAX_FRAME = 16_777_216

def refuse[T](message: String) -> Result[T] = error("cluster: #{message}", kind: Types.ARGUMENT)

def frame_limit_bad?(options: Types.Options) -> Bool
  options.max_frame_bytes < Types.PRE_AUTH_MAX_FRAME_BYTES or options.max_frame_bytes > MAX_FRAME
end

# Without TLS, the frames after the handshake have no secrecy or integrity: plain TCP stays on this machine unless the
# options say that the network is trusted.
def plain_allowed(host: String, insecure_plaintext: Bool) -> Result[Void]
  return ok() if insecure_plaintext or Address.loopback?(host)

  refuse("plain TCP is only for this machine; set insecure_plaintext for a trusted network")
end

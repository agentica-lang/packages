## The opening handshake of RFC 6455 for a client (section 4.1), as pure functions: the URL, the request text, and the
## check of the answer. The socket is in `connection.agc`.

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_PORT = 65_535
SWITCHING = 101
# The bytes of a token (RFC 9110 5.6.2): what the name of a header and of a subprotocol are made of.
TOKEN_BYTES = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".bytes
# The headers that the handshake writes itself: a caller that sets one of them would break it.
OWNED = [
  "host",
  "upgrade",
  "connection",
  "sec-websocket-key",
  "sec-websocket-version",
  "sec-websocket-protocol",
  "sec-websocket-extensions",
]

## Where a `ws://` or `wss://` URL points: the `path` has the query, and is "/" for none.
export struct Target
  secure: Bool
  host: String
  port: Int
  path: String
end

# A host and a port; the port 0 stands for none.
struct Address
  host: String
  port: Int
end

## The `Sec-WebSocket-Accept` for a `Sec-WebSocket-Key` (RFC 6455 4.2.2): the base64 of the SHA-1 of the key and the
## GUID.
export def accept_key(key: String) -> String = Base64.strict_encode64(OpenSSL.Digest.sha1("#{key}#{GUID}".bytes))

## The target of a `ws://` or `wss://` URL. The fragment is dropped (RFC 6455 3 forbids it), and user info is refused:
## credentials go in a header. An IPv6 host goes in brackets.
export def parse_url(url: String) -> Result[Target]
  return error("the URL must be ASCII with no space or control character: #{url}") if not plain?(url)

  secure = url.downcase.start_with?("wss://")
  if not secure and not url.downcase.start_with?("ws://")
    return error("the URL must start with ws:// or wss://: #{url}")
  end

  scheme_size = 5
  if secure
    scheme_size = 6
  end

  rest = url.slice(scheme_size, url.length - scheme_size).split("#")[0]
  at = first_of(rest, ["/", "?"])
  authority = rest.slice(0, at)
  path = rest.slice(at, rest.length - at)
  if not path.start_with?("/")
    path = "/#{path}"
  end

  return error("the URL has user info, send credentials in a header: #{url}") if authority.include?("@")

  address = try split_authority(authority, url)
  port = address.port
  if port == 0
    port = default_port(secure)
  end

  ok(Target(secure: secure, host: address.host, port: port, path: path))
end

## The `Host` header of a target: the port is left out when it is the default of the scheme.
export def host_header(target: Target) -> String
  host = target.host
  if host.include?(":")
    host = "[#{host}]"
  end

  return host if target.port == default_port(target.secure)

  "#{host}:#{target.port}"
end

## The text of the handshake request for the `key` (the base64 of 16 random bytes), with the subprotocols that the
## client offers and the extra headers of the caller. An `error` for a header that the handshake owns, a name that is
## not a token and a value with a line break.
export def request(target: Target, key: String, protocols: List[String], headers: List[Header]) -> Result[String]
  lines = [
    "GET #{target.path} HTTP/1.1",
    "Host: #{host_header(target)}",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: #{key}",
    "Sec-WebSocket-Version: 13",
  ]

  if not protocols.empty?
    for name in protocols
      return error("a subprotocol must be a token: #{name}") if not token?(name)
    end

    lines = lines.push("Sec-WebSocket-Protocol: #{protocols.join(", ")}")
  end

  for header in headers
    try check_header(header)
    lines = lines.push("#{header.name}: #{header.value}")
  end

  ok(lines.join("\r\n") + "\r\n\r\n")
end

## The subprotocol that the server chose ("" for none), when its answer is a good handshake: status 101, `Upgrade` and
## `Connection` as RFC 6455 4.2.2 says, the accept of the `key`, a subprotocol that the client offered, and no
## extension (the client offers none). `lines` are the head of the answer without their line ends.
export def check_response(lines: List[String], key: String, protocols: List[String]) -> Result[String]
  return error("the server sent no answer") if lines.empty?

  status = try status_of(lines[0])
  return error("the server answered #{status}, not 101") if status != SWITCHING

  fields = lines.drop(1)
  upgrade = values_of(fields, "upgrade").any? do |value| has_token?(value, "websocket") end
  return error("the answer has no Upgrade: websocket") if not upgrade

  connection = values_of(fields, "connection").any? do |value| has_token?(value, "upgrade") end
  return error("the answer has no Connection: Upgrade") if not connection

  accepts = values_of(fields, "sec-websocket-accept")
  if accepts.size != 1 or accepts[0].strip != accept_key(key)
    return error("the Sec-WebSocket-Accept of the answer is missing or wrong")
  end

  if not values_of(fields, "sec-websocket-extensions").empty?
    return error("the server chose an extension that the client did not offer")
  end

  chosen = values_of(fields, "sec-websocket-protocol")
  return ok("") if chosen.empty?

  name = chosen[0].strip
  if chosen.size > 1 or not protocols.include?(name)
    return error("the server chose a subprotocol that the client did not offer: #{chosen.join(", ")}")
  end

  ok(name)
end

def default_port(secure: Bool) -> Int
  return 443 if secure

  80
end

def split_authority(authority: String, url: String) -> Result[Address]
  host = authority
  port_text = ""
  if authority.start_with?("[")
    close = authority.index_of("]")
    return error("the URL has an IPv6 host with no ]: #{url}") if close.none?

    host = authority.slice(1, close.unwrap! - 1)
    port_text = authority.slice(close.unwrap! + 1, authority.length - close.unwrap! - 1)
    if not port_text.empty? and not port_text.start_with?(":")
      return error("the URL has text after the IPv6 host: #{url}")
    end
  else
    parts = authority.split(":")
    return error("the URL has a bad host: #{url}") if parts.size > 2

    host = parts[0]
    if parts.size == 2
      port_text = ":#{parts[1]}"
    end
  end

  return error("the URL has no host: #{url}") if host.empty?

  return ok(Address(host: host, port: 0)) if port_text.empty?

  port = try port_text.slice(1, port_text.length - 1).to_i
  return error("the URL has a port outside 1 to #{MAX_PORT}: #{url}") if port < 1 or port > MAX_PORT

  ok(Address(host: host, port: port))
end

# The first place of one of `marks` in `text`, or its end.
def first_of(text: String, marks: List[String]) -> Int
  found = text.length
  for mark in marks
    case text.index_of(mark)
      some(at) ->
        if at < found
          found = at
        end

      none -> nil
    end
  end

  found
end

# No byte outside the printable ASCII: a space or a control byte would break the request line.
def plain?(text: String) -> Bool
  for byte in text.bytes
    return false if byte <= 32 or byte >= 127
  end

  true
end

def token?(name: String) -> Bool
  return false if name.empty?

  for byte in name.bytes
    return false if not TOKEN_BYTES.to_a.include?(byte)
  end

  true
end

# A NUL, a CR or an LF in a value would end the line, or the head, early (header injection).
def clean?(value: String) -> Bool
  for byte in value.bytes
    return false if byte == 0 or byte == 10 or byte == 13
  end

  true
end

def check_header(header: Header) -> Result[Void]
  return error("a header name must be a token: \"#{header.name}\"") if not token?(header.name)

  return error("#{header.name} is written by the handshake itself") if OWNED.include?(header.name.downcase)

  return error("the value of #{header.name} has a line break") if not clean?(header.value)

  ok()
end

def status_of(line: String) -> Result[Int]
  parts = line.split(" ")
  return error("the answer is not HTTP: #{line}") if parts.size < 2 or not parts[0].start_with?("HTTP/1.")

  parts[1].to_i
end

# The values of the header `name` (lowercase) in every field, as written; a line with no colon has none.
def values_of(fields: List[String], name: String) -> List[String]
  values: List[String] = []
  for field in fields
    case field.index_of(":")
      some(colon) ->
        if field.slice(0, colon).strip.downcase == name
          values = values.push(field.slice(colon + 1, field.length - colon - 1))
        end

      none -> nil
    end
  end

  values
end

# True when `value`, a comma-separated list as in `Connection` and `Upgrade`, has `token`, as HTTP compares names.
def has_token?(value: String, token: String) -> Bool
  for part in value.split(",")
    return true if part.strip.downcase == token
  end

  false
end

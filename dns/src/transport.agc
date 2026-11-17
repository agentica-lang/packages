## One query to a nameserver: over a stream, the message with its 2-byte length in front (RFC 7766 8), on TCP or on TCP
## with TLS (RFC 7858), or as the body of an HTTPS POST (RFC 8484). Each exchange has its own connection and one
## deadline for all of it.

import Binary from "std/binary"
import HTTP from "std/http"
import Types from "types"

## Sends `query` to the server and returns the bytes of the answer. An `error` of the kind `dns.timeout` when the
## deadline passes, `dns.network` when the connection breaks, or ends before the whole answer, and `dns.malformed` for
## a length of 0.
def exchange(server: Types.Server, query: Bytes, timeout_ms: Int, context: Optional[TLS.Context]) -> Result[Bytes]
  deadline = Time.monotonic_ms() + timeout_ms
  case server
    Types.Server.Https(url) -> return post(url, query, context, deadline)
    _ -> nil
  end

  socket = try dial(server, context, timeout_ms, deadline)
  answer = talk(socket, query, deadline)
  TCP.close(socket)
  answer
end

private

READ_STEP_BYTES = 4096
MEDIA_TYPE = "application/dns-message"

# The query as the body of a POST, and the body of the answer, which must be a 200 of the media type of DNS messages.
def post(url: String, query: Bytes, context: Optional[TLS.Context], deadline: Int) -> Result[Bytes]
  options = HTTP.ClientOptions(timeout_ms: try left(deadline), max_body_bytes: Types.MAX_ANSWER_BYTES, tls: context)
  headers = [HTTP.Header(name: "Content-Type", value: MEDIA_TYPE), HTTP.Header(name: "Accept", value: MEDIA_TYPE)]
  response = try broken(HTTP.post_response(url, query, headers, options), deadline, "asking #{url}")
  return error("dns: #{url} answered #{response.status}", kind: Types.NETWORK) if response.status != 200

  types = HTTP.header_values(response.headers, "content-type")
  if types.empty? or not types[0].downcase.start_with?(MEDIA_TYPE)
    return error("dns: #{url} did not answer with #{MEDIA_TYPE}", kind: Types.MALFORMED)
  end

  ok(response.body)
end

def talk(socket: TCP.Socket, query: Bytes, deadline: Int) -> Result[Bytes]
  framed = Bytes.concat([try Binary.write_u16_be(query.size), query])
  try broken(TCP.send_bytes(socket, framed, try left(deadline)), deadline, "sending the query")
  head = try read_exact(socket, 2, deadline)
  size = try Binary.read_u16_be(head, 0)
  return error("dns: an answer of 0 bytes", kind: Types.MALFORMED) if size == 0
  read_exact(socket, size, deadline)
end

def dial(server: Types.Server, context: Optional[TLS.Context], timeout_ms: Int, deadline: Int) -> Result[TCP.Socket]
  case server
    Types.Server.Tcp(host, port) -> broken(TCP.connect(host, port, timeout_ms), deadline, "connecting to #{host}")
    Types.Server.Https(url) -> error("dns: #{url} is not a stream", kind: Types.MALFORMED)
    Types.Server.Tls(host, port, name) ->
      socket = try broken(TCP.connect(host, port, timeout_ms), deadline, "connecting to #{host}")
      checked = name
      if name == ""
        checked = host
      end

      case TLS.upgrade(socket, try trust(context), checked, try left(deadline))
        ok(secure) -> ok(secure)
        error(e) ->
          TCP.close(socket)
          broken(error(e), deadline, "the TLS handshake with #{host}")
      end
  end
end

def trust(context: Optional[TLS.Context]) -> Result[TLS.Context]
  case context
    some(found) -> ok(found)
    none -> error("dns: a TLS server needs a TLS context", kind: Types.MALFORMED)
  end
end

def read_exact(socket: TCP.Socket, count: Int, deadline: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    want = count - have
    if want > READ_STEP_BYTES
      want = READ_STEP_BYTES
    end

    chunk = try broken(TCP.recv_bytes(socket, want, try left(deadline)), deadline, "reading the answer")
    return error("dns: the server closed the connection before the whole answer", kind: Types.NETWORK) if chunk.empty?

    parts = parts.push(chunk)
    have += chunk.size
  end

  ok(Bytes.concat(parts))
end

# The milliseconds until the deadline, or a timeout `error` when it has passed.
def left(deadline: Int) -> Result[Int]
  time = deadline - Time.monotonic_ms()
  return error("dns: no answer in time", kind: Types.TIMEOUT) if time < 1
  ok(time)
end

# A failed step as an `error` of the package: a timeout when the deadline is the reason, a network error otherwise.
def broken[T](result: Result[T], deadline: Int, what: String) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) ->
      if Time.monotonic_ms() >= deadline
        return error("dns: no answer in time (#{what})", kind: Types.TIMEOUT, cause: e)
      end

      error("dns: #{what}: #{e.message}", kind: Types.NETWORK, cause: e)
  end
end

import Frame from "../../src/http2/frame"
import Hpack from "pkg/hpack/hpack"

def serve(listener: TCP.Listener, pinged: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000200000000000400000008"))
  first = try read_headers(socket, 1)
  try expect_request(first, "GET", "/first")
  try send(socket, 1, 5, 1, hex("884006782d74657374036f6e65"))
  try send(socket, 6, 0, 0, "idleping".bytes)
  ping = try read(socket)
  if ping.kind != 6 or ping.flags != 1 or ping.payload != "idleping".bytes
    return error("missing idle ping acknowledgment")
  end

  try pinged.send(true, WAIT)
  second = try read_headers(socket, 3)
  try expect_request(second, "POST", "/second")
  try upload(socket)
  try send(socket, 1, 4, 3, hex("0803313033"))
  try send(socket, 1, 0, 3, hex("88"))
  try send(socket, 9, 4, 3, hex("be"))
  try download(socket)
  TCP.close(socket)
  replacement = try TCP.accept(listener, WAIT)
  try handshake(replacement, "".bytes)
  third = try read_headers(replacement, 1)
  try expect_request(third, "head", "/third")
  if (not third.any? { |field| field.name == "x-parity".bytes and field.value == hex("636166e9") })
    return error("expected Latin-1 request header")
  end

  try send(replacement, 1, 4, 1, hex("880008782d70617269747904636166e9"))
  try send(replacement, 0, 1, 1, "extension".bytes)
  TCP.close(replacement)
  ok()
end

def serve_tls(listener: TCP.Listener, h2: Bool) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  if h2
    try handshake(socket, "".bytes)
    fields = try read_headers(socket, 1)
    try expect_request(fields, "POST", "/tls")
    if (not fields.any? { |field| field.name == "content-length".bytes and field.value == "0".bytes })
      return error("expected zero content length")
    end

    try send(socket, 1, 5, 1, hex("88"))
  end

  TCP.close(socket)
  ok()
end

def refuse_start(listener: TCP.Listener, settings: Bytes, after_settings: Bytes) -> Result[Void]
  try refuse_socket(listener, settings, after_settings)
  return ok() if after_settings.empty?
  refuse_socket(listener, settings, after_settings)
end

def early_post(listener: TCP.Listener) -> Result[Void]
  goaway = Frame.encode(7, 0, 0, Frame.word(0) + Frame.word(0))
  try refuse_socket(listener, hex("000300000000"), goaway)
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000400010000"))
  headers = try read_headers(socket, 1)
  try expect_request(headers, "POST", "/early")
  body = ("r" * 16_384).bytes
  wire = (
    Frame.encode(6, 0, 0, "ping-one".bytes) +
    Frame.encode(4, 0, 0, "".bytes) +
    Frame.encode(6, 0, 0, "ping-two".bytes) +
    Frame.encode(1, 4, 1, hex("0803343133")) +
    Frame.encode(0, 0, 1, body) +
    Frame.encode(0, 0, 1, body) +
    Frame.encode(0, 1, 1, "tail".bytes)
  )

  try TCP.send_bytes(socket, wire, WAIT)
  TCP.close(socket)
  ok()
end

def stalled(listener: TCP.Listener, wait_for_settings: Bool) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  if wait_for_settings
    _ = try exact(socket, 24)
    _ = try read(socket)
  else
    try handshake(socket, "".bytes)
    _ = try read_headers(socket, 1)
  end

  expect_closed(socket)
end

def expect_closed(socket: TCP.Socket) -> Result[Void]
  case TCP.recv_bytes(socket, 1, WAIT)
    ok(bytes) if bytes.empty? -> ok()
    error(e) if e.is_a?("net.closed") -> ok()
    _ -> error("client did not close the stalled session")
  end
end

def failover(listener: TCP.Listener) -> Result[Void]
  try stalled(listener, true)
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  fields = try read_headers(socket, 1)
  try expect_request(fields, "GET", "/")
  send(socket, 1, 5, 1, hex("88"))
end

def wait_for_close(listener: TCP.Listener, started: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  _ = try read_headers(socket, 1)
  try started.send(true, WAIT)
  expect_closed(socket)
end

def idle_until_close(listener: TCP.Listener, release: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  _ = try read_headers(socket, 1)
  try send(socket, 1, 5, 1, hex("88"))
  try expect_closed(socket)
  _ = try release.recv(WAIT)
  ok()
end

private

WAIT = 5_000

def refuse_socket(listener: TCP.Listener, settings: Bytes, after_settings: Bytes) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  _ = try exact(socket, 24)
  _ = try read(socket)
  wire = Frame.encode(4, 0, 0, settings) + after_settings
  try TCP.send_bytes(socket, wire, WAIT)
  case read(socket)
    ok(frame) if frame.kind == 4 and frame.flags == 1 ->
      case read(socket)
        error(_) -> ok()
        ok(_) -> error("client opened a stream after startup goaway")
      end

    error(_) -> ok()
    ok(_) -> error("client opened a stream after startup refusal")
  end
end

def handshake(socket: TCP.Socket, settings: Bytes) -> Result[Void]
  preface = try exact(socket, 24)
  return error("wrong connection preface") if preface != "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".bytes
  first = try read(socket)
  return error("expected client settings") if first.kind != 4 or first.payload != hex("000200000000")
  try send(socket, 4, 0, 0, settings)
  ack = try read(socket)
  return error("expected settings acknowledgment") if ack.kind != 4 or ack.flags != 1
  ok()
end

def upload(socket: TCP.Socket) -> Result[Void]
  first = try read(socket)
  if first.kind != 0 or first.stream != 3 or first.flags != 0 or first.payload != ("u" * 8).bytes
    return error("first upload frame exceeded the stream window")
  end

  try send(socket, 4, 0, 0, hex("000400000000"))
  ack = try read(socket)
  return error("missing acknowledgment for changed initial window") if ack.kind != 4 or ack.flags != 1
  after_stream = try resumed(socket, 3, 70_000)
  try read_upload(socket, after_stream, 65_535 - 8, false)
  after_connection = try resumed(socket, 0, 10_000)
  read_upload(socket, after_connection, 70_000 - 65_535, true)
end

def read_upload(socket: TCP.Socket, first: Frame.Frame, count: Int, ending: Bool) -> Result[Void]
  left = count
  frame = first
  while left > 0
    size = frame.payload.size
    if frame.kind != 0 or frame.stream != 3 or size == 0 or size > left or frame.payload != ("u" * size).bytes
      return error("invalid upload data")
    end

    left = left - size
    return error("wrong upload end_stream") if (frame.flags == 1) != (left == 0 and ending)
    if left > 0
      frame = try read(socket)
    end
  end

  ok()
end

def resumed(socket: TCP.Socket, id: Int, credit: Int) -> Result[Frame.Frame]
  reader = Task.spawn do read(socket) end
  case Task.await(reader, 40)
    Await.Done(_) -> return error("upload sent despite an exhausted window")
    _ -> nil
  end

  try send(socket, 8, 0, id, Frame.word(credit))
  Task.await(reader)
end

def download(socket: TCP.Socket) -> Result[Void]
  for _ in 1..3
    try send(socket, 0, 0, 3, ("d" * 16_384).bytes)
  end

  conn = try read(socket)
  stream = try read(socket)
  if conn.kind != 8 or conn.stream != 0 or Frame.u32(conn.payload, 0) != 32_768
    return error("missing connection window refill")
  end

  if stream.kind != 8 or stream.stream != 3 or Frame.u32(stream.payload, 0) != 32_768
    return error("missing stream window refill")
  end

  try send(socket, 0, 0, 3, ("d" * 16_384).bytes)
  for _ in 1..2
    refill = try read(socket)
    return error("missing second window refill") if refill.kind != 8
  end

  try send(socket, 7, 0, 0, Frame.word(3) + Frame.word(0))
  try send(socket, 0, 8, 3, hex("01") + ("d" * 4_464).bytes + hex("00"))
  send(socket, 1, 5, 3, hex("0007782d747261696c03796573"))
end

def read_headers(socket: TCP.Socket, id: Int) -> Result[List[Hpack.Header]]
  frame = try read(socket)
  if frame.kind != 1 or frame.stream != id or frame.flags.bit_and(4) == 0
    return error("wrong request stream or missing headers")
  end

  decoded = try Hpack.decode(Hpack.decoder(), frame.payload)
  ok(decoded.headers)
end

def expect_request(headers: List[Hpack.Header], method: String, path: String) -> Result[Void]
  for header in headers
    if header.name == ":method".bytes and header.value != method.bytes
      return error("wrong method")
    elsif header.name == ":path".bytes and header.value != path.bytes
      return error("wrong path")
    end
  end

  if (not headers.any? { |h| h.name == ":method".bytes } or not headers.any? { |h| h.name == ":path".bytes })
    return error("missing request pseudo-header")
  end

  ok()
end

def read(socket: TCP.Socket) -> Result[Frame.Frame]
  head = try exact(socket, 9)
  size = head[0] * 65536 + head[1] * 256 + head[2]
  payload = try exact(socket, size)
  parsed = try Frame.parse(head + payload)
  ok(parsed.unwrap!.frame)
end

def exact(socket: TCP.Socket, size: Int) -> Result[Bytes]
  bytes = "".bytes
  while bytes.size < size
    chunk = try TCP.recv_bytes(socket, size - bytes.size, WAIT)
    return error("the client closed early") if chunk.empty?
    bytes = bytes + chunk
  end

  ok(bytes)
end

def send(socket: TCP.Socket, kind: Int, flags: Int, stream: Int, payload: Bytes) -> Result[Void]
  TCP.send_bytes(socket, Frame.encode(kind, flags, stream, payload), WAIT)
end

def hex(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

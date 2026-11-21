import Frame from "../../../src/http2/frame"
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

def streaming(listener: TCP.Listener, resumed: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  headers = try read_headers(socket, 1)
  try expect_request(headers, "GET", "/stream")
  try send(socket, 1, 4, 1, hex("88"))
  try send(socket, 0, 0, 1, "first".bytes)
  _ = try resumed.recv(WAIT)
  try send(socket, 0, 1, 1, "second".bytes)
  TCP.close(socket)
  ok()
end

def streaming_cancel(listener: TCP.Listener) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  headers = try read_headers(socket, 1)
  try expect_request(headers, "GET", "/cancel")
  try send(socket, 1, 4, 1, hex("88"))
  try send(socket, 0, 0, 1, "first".bytes)
  try await_reset(socket, 1, "cancelled stream")

  next_headers = try read_headers(socket, 3)
  try expect_request(next_headers, "GET", "/after")
  try send(socket, 1, 4, 3, hex("88"))
  try send(socket, 0, 1, 3, "after".bytes)
  expect_closed(socket)
end

def streaming_idle(listener: TCP.Listener) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  headers = try read_headers(socket, 1)
  try expect_request(headers, "GET", "/idle")
  try send(socket, 1, 4, 1, hex("88"))
  try send(socket, 0, 0, 1, "first".bytes)
  try await_reset(socket, 1, "idle stream")

  expect_closed(socket)
end

def streaming_flow(listener: TCP.Listener) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  headers = try read_headers(socket, 1)
  try expect_request(headers, "GET", "/flow")
  try send(socket, 1, 4, 1, hex("88"))
  chunk = ("f" * 16_384).bytes
  try send(socket, 0, 0, 1, chunk)
  try send(socket, 0, 0, 1, chunk)
  try send(socket, 0, 0, 1, ("g" * 7_232).bytes)
  try await_refill(socket, 1)
  try send(socket, 0, 1, 1, "tail".bytes)
  drain_updates(socket)
end

# Reads until the peer resets `id`: window updates of a streamed body arrive before its reset, so they
# are skipped rather than treated as the reset.
def await_reset(socket: TCP.Socket, id: Int, what: String) -> Result[Void]
  while true
    outcome = read(socket)
    case outcome
      ok(frame) if frame.kind == 3 and frame.stream == id -> return ok()
      ok(frame) if frame.kind == 8 -> nil
      ok(_) -> return error("expected reset for #{what}")
      error(e) if e.message == "the client closed early" -> return ok()
      error(e) if e.is_a?("net.closed") -> return ok()
      error(e) -> return error(e.message)
    end
  end

  ok()
end

# Drains window updates until the client closes: the tail brings its own refill, so the count is not
# fixed and every update is skipped.
def drain_updates(socket: TCP.Socket) -> Result[Void]
  while true
    outcome = read(socket)
    case outcome
      ok(frame) if frame.kind == 8 -> nil
      ok(_) -> return error("unexpected frame before close")
      error(e) if e.message == "the client closed early" -> return ok()
      error(e) if e.is_a?("net.closed") -> return ok()
      error(e) -> return error(e.message)
    end
  end

  ok()
end

# Reads until the stream window grows: connection updates may come first, so they are skipped.
def await_refill(socket: TCP.Socket, id: Int) -> Result[Void]
  while true
    frame = try read(socket)
    return ok() if frame.kind == 8 and frame.stream == id

    return error("missing stream window refill for streamed flow") if frame.kind != 8 or frame.stream != 0
  end

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
    case read(socket)
      ok(reset) if reset.kind == 3 and reset.stream == 1 -> nil
      ok(_) -> return error("expected reset or close")
      error(_) -> return ok()
    end
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
  try handshake(socket, hex("000300000001"))
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

def multiplex(listener: TCP.Listener, started: Channel[Bool], finished: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000400000000"))
  post = try read_headers(socket, 1)
  try expect_request(post, "POST", "/blocked")
  try started.send(true, WAIT)
  get = try read_headers(socket, 3)
  try expect_request(get, "GET", "/fast")
  try send(socket, 1, 4, 3, hex("884006782d74657374036f6e65"))
  try send(socket, 0, 1, 3, "fast".bytes)
  _ = try finished.recv(WAIT)
  try send(socket, 8, 0, 1, Frame.word(8))
  body = try read(socket)
  if body.kind != 0 or body.stream != 1 or body.flags != 1 or body.payload != "upload".bytes
    return error("the blocked upload did not resume")
  end

  try send(socket, 1, 4, 1, hex("88be"))
  try send(socket, 0, 1, 1, "slow".bytes)
  expect_closed(socket)
end

def cancelled(listener: TCP.Listener, waiting: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000300000002"))
  first = try read_headers(socket, 1)
  try expect_request(first, "GET", "/cancelled")
  try send(socket, 4, 0, 0, hex("000300000000"))
  try settings_ack(socket)
  try send(socket, 1, 0, 1, hex("884006782d74657374"))
  try waiting.send(true, 0)
  reset = try read(socket)
  if reset.kind != 3 or reset.stream != 1 or reset.payload != Frame.word(8)
    return error("expected cancellation while new streams were paused")
  end

  try send(socket, 9, 4, 1, hex("036f6e65"))
  try send(socket, 4, 0, 0, hex("000300000001"))
  try settings_ack(socket)
  next_headers = try read_headers(socket, 3)
  try expect_request(next_headers, "GET", "/queued")
  try send(socket, 1, 5, 3, hex("88be"))
  expect_closed(socket)
end

def shared_window(listener: TCP.Listener, started: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000400000000"))
  first = try read_headers(socket, 1)
  try expect_request(first, "POST", "/one")
  try started.send(true, WAIT)
  second = try read_headers(socket, 3)
  try expect_request(second, "POST", "/two")
  try send(socket, 4, 0, 0, hex("00040000ffff"))
  try settings_ack(socket)
  blocked = try take_upload(socket, Upload(), 65_535)
  return error("both streams must receive upload credit") if blocked.one == 0 or blocked.two == 0
  next_frame = try resumed(socket, 0, 10_000)
  prefix = try count_upload(blocked, next_frame)
  final = try take_upload(socket, prefix, 70_000)
  return error("wrong upload sizes or end flags") if final.one != 35_000 or final.two != 35_000
  try send(socket, 7, 0, 0, Frame.word(3) + Frame.word(0))
  try send(socket, 1, 5, 3, hex("88"))
  try send(socket, 1, 5, 1, hex("88"))
  try expect_closed(socket)
  replacement = try TCP.accept(listener, WAIT)
  try handshake(replacement, "".bytes)
  headers = try read_headers(replacement, 1)
  try expect_request(headers, "GET", "/after-goaway")
  try send(replacement, 1, 5, 1, hex("88"))
  expect_closed(replacement)
end

def broken(listener: TCP.Listener, started: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  _ = try read_headers(socket, 1)
  try started.send(true, WAIT)
  _ = try read_headers(socket, 3)
  wire = Frame.encode(1, 4, 1, hex("88")) + Frame.encode(0, 0, 1, "part".bytes) + Frame.encode(0, 1, 1, "done".bytes)
  try TCP.send_bytes(socket, wire, WAIT)
  TCP.close(socket)
  replacement = try TCP.accept(listener, WAIT)
  try handshake(replacement, "".bytes)
  headers = try read_headers(replacement, 1)
  try expect_request(headers, "GET", "/replacement")
  try send(replacement, 1, 5, 1, hex("88"))
  expect_closed(replacement)
end

def surplus(listener: TCP.Listener, started: Channel[Bool]) -> Result[Void]
  busy = try TCP.accept(listener, WAIT)
  try handshake(busy, hex("000300000001"))
  _ = try read_headers(busy, 1)
  try started.send(true, WAIT)
  spare = try TCP.accept(listener, WAIT)
  try handshake(spare, "".bytes)
  _ = try read_headers(spare, 1)
  try send(spare, 1, 5, 1, hex("88"))
  try expect_closed(spare)
  try send(busy, 1, 5, 1, hex("88"))
  expect_closed(busy)
end

def malformed(listener: TCP.Listener, started: Channel[Bool], mode: Int) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, "".bytes)
  _ = try read_headers(socket, 1)
  try started.send(true, WAIT)
  _ = try read_headers(socket, 3)
  case mode
    0 -> try send(socket, 1, 4, 1, hex("880f0d01324006782d74657374036f6e65"))
    1 -> try send(socket, 1, 5, 1, hex("4006782d74657374036f6e65"))
    2 -> nil
    _ -> try send(socket, 1, 4, 1, hex("894006782d74657374036f6e65"))
  end

  if mode == 2
    padded = Bytes.from_list([1]).unwrap! + ("m" * 16_382).bytes + Frame.word(0).take(1)
    try send(socket, 0, 9, 1, padded)
  elsif mode != 1
    try send(socket, 0, 1, 1, "x".bytes)
  end

  reset = try read(socket)
  if reset.kind != 3 or reset.stream != 1 or reset.payload != Frame.word(1)
    return error("expected a stream protocol error")
  end

  if mode == 2
    try send(socket, 1, 4, 3, hex("88"))
    try send(socket, 0, 0, 3, ("d" * 16_384).bytes)
    credit = try read(socket)
    if credit.kind != 8 or credit.stream != 0 or credit.payload != Frame.word(32_768)
      return error("malformed padded DATA was not charged against the connection window")
    end

    try send(socket, 0, 1, 3, "".bytes)
  else
    try send(socket, 1, 5, 3, hex("88be"))
  end

  expect_closed(socket)
end

def skipped_end(
  listener: TCP.Listener,
  blocked: Channel[Bool],
  cleared: Channel[Bool],
  peer_resets: Bool,
) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000300000001"))
  _ = try read_headers(socket, 1)
  _ = try blocked.recv(WAIT)
  wire = Frame.encode(1, 4, 1, hex("0803343133")) + Frame.encode(0, 1, 1, "complete".bytes)
  if peer_resets
    wire = wire + Frame.encode(3, 0, 1, Frame.word(0))
  end

  try TCP.send_bytes(socket, wire, WAIT)

  first = try read(socket)
  if first.kind != 0 or first.stream != 1 or first.flags != 0
    return error("expected the first DATA without end_stream")
  end

  if not peer_resets
    reset = try read(socket)
    if reset.kind != 3 or reset.stream != 1 or reset.payload != Frame.word(8)
      return error("the expired final DATA did not release its stream slot")
    end
  end

  try cleared.send(true, WAIT)
  later = try read_headers(socket, 3)
  try expect_request(later, "GET", "/after")
  try send(socket, 1, 5, 3, hex("88"))
  expect_closed(socket)
end

def eof_during_upload(listener: TCP.Listener, blocked: Channel[Bool]) -> Result[Void]
  socket = try TCP.accept(listener, WAIT)
  try handshake(socket, hex("000300000001"))
  _ = try read_headers(socket, 1)
  _ = try blocked.recv(WAIT)
  try send(socket, 1, 4, 1, hex("0803343133"))
  Task.sleep(10)
  wire = Frame.encode(0, 1, 1, "complete".bytes)
  split = wire.size - 4
  try TCP.send_bytes(socket, wire.slice(0, split), WAIT)
  Task.sleep(10)
  try TCP.send_bytes(socket, wire.drop(split), WAIT)
  TCP.close(socket)
  ok()
end

private

WAIT = 5_000

struct Upload
  one: Int = 0
  two: Int = 0
end

def take_upload(socket: TCP.Socket, prefix: Upload, limit: Int) -> Result[Upload]
  total = prefix
  while total.one + total.two < limit
    frame = try read(socket)
    total = try count_upload(total, frame)
  end

  return error("connection credit was exceeded") if total.one + total.two != limit
  ok(total)
end

def count_upload(prefix: Upload, frame: Frame.Frame) -> Result[Upload]
  if frame.kind != 0 or (frame.stream != 1 and frame.stream != 3) or frame.payload.empty?
    return error("expected DATA on an active stream")
  end

  previous = prefix.two
  if frame.stream == 1
    previous = prefix.one
  end

  size = previous + frame.payload.size
  return error("incorrect DATA length or end flag") if size > 35_000 or (frame.flags == 1) != (size == 35_000)

  return ok(prefix.with(one: size)) if frame.stream == 1
  ok(prefix.with(two: size))
end

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

def settings_ack(socket: TCP.Socket) -> Result[Void]
  ack = try read(socket)
  return error("expected settings acknowledgment") if ack.kind != 4 or ack.flags != 1
  ok()
end

def handshake(socket: TCP.Socket, settings: Bytes) -> Result[Void]
  preface = try exact(socket, 24)
  return error("wrong connection preface") if preface != "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".bytes
  first = try read(socket)
  return error("expected client settings") if first.kind != 4 or first.payload != hex("000200000000")
  try send(socket, 4, 0, 0, settings)
  settings_ack(socket)
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

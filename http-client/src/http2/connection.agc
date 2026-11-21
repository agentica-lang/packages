import Frame from "frame"
import Headers from "headers"
import Hpack from "pkg/hpack/hpack"
import HTTP from "std/http"
import Url from "../url"

struct Request
  method: String
  target: Url.Target
  headers: List[HTTP.Header]
  body: Bytes
  read_timeout_ms: Int
  body_idle_ms: Int
  deadline: Int
  max_body_bytes: Int
end

struct Response
  status: Int
  headers: List[HTTP.Header]
  body: Bytes
end

struct Write
  bytes: Bytes
  stream: Int = 0
  deadline: Optional[Int] = none
  cancelled: Optional[Channel[Bool]] = none
  credit: Int = 0
  opening: Bool = false
  end_stream: Bool = false
  reset: Bool = false
end

struct Session
  socket: TCP.Socket
  incoming: Channel[Bytes]
  reader: Task[Result[Void]]
  decoder: Hpack.DecoderState
  buffer: Bytes = "".bytes
  next_stream: Int = 1
  send_credit: Int = 65_535
  receive_credit: Int = 65_535
  initial_window: Int = 65_535
  frame_size: Int = 16_384
  stream_limit: Int = 100
  last_stream: Int = 0x7fffffff
  draining: Bool = false
  write_error: Optional[Error] = none
  writer: Optional[Channel[Write]] = none
end

enum StreamPhase
  Open
  HalfClosedLocal
  HalfClosedRemote
  Closed
end

struct Stream
  id: Int
  phase: StreamPhase = StreamPhase.Open
  cancelled: Optional[Channel[Bool]] = none
  send_credit: Int
  receive_credit: Int = 65_535
  sent: Int = 0
  status: Int = 0
  fields: List[HTTP.Header] = []
  parts: List[Bytes] = []
  received: Int = 0
  ended: Bool = false
  block: Bytes = "".bytes
  continuing: Bool = false
  end_on_headers: Bool = false
  expected_size: Optional[Int] = none
end

struct Progress
  session: Session
  stream: Stream
  malformed: Optional[String] = none
end

struct Read
  frame: Frame.Frame
  session: Session
end

def start(socket: TCP.Socket, incoming: Channel[Bytes], reader: Task[Result[Void]], deadline: Int) -> Result[Session]
  session = Session(socket: socket, incoming: incoming, reader: reader, decoder: Hpack.decoder())
  preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".bytes
  settings = Frame.encode(4, 0, 0, Bytes.from_list([0, 2, 0, 0, 0, 0]).unwrap!)
  try TCP.send_bytes(socket, preface + settings, try remaining(deadline))
  read = try read_frame(session, deadline)
  first = read.frame
  return Frame.invalid("expected initial settings") if first.kind != 4 or flag?(first, 1)
  started = try control(read.session, first, deadline)
  case started.write_error
    some(e) -> error(e)
    none -> ok(started)
  end
end

def reusable?(session: Session) -> Bool
  session.write_error.none? and not session.draining and session.next_stream <= Frame.MAX_WINDOW
end

def open_stream(session: Session, req: Request, block: Bytes, deadline: Int) -> Result[Progress]
  id = session.next_stream
  cancel: Channel[Bool] = Channel.new(1)
  try send_headers(session, id, block, req.body.empty?, deadline, cancel)
  phase = StreamPhase.Open
  if req.body.empty?
    phase = StreamPhase.HalfClosedLocal
  end

  ok(
    Progress(
      session: session.with(next_stream: id + 2),
      stream: Stream(id: id, send_credit: session.initial_window, phase: phase, cancelled: some(cancel)),
    ),
  )
end

def pull(session: Session, deadline: Int) -> Result[Session] = read_available(session, deadline)

def dispatch(session: Session, frame: Frame.Frame, deadline: Int) -> Result[Session]
  idle_control(session, frame, deadline)
end

def dispatch_stream(state: Progress, frame: Frame.Frame, req: Request, deadline: Int) -> Result[Progress]
  updated = try receive(state, frame, req, deadline)
  stream = updated.stream
  return ok(updated) if not stream.ended
  phase = StreamPhase.HalfClosedRemote
  if stream.phase == StreamPhase.HalfClosedLocal
    phase = StreamPhase.Closed
  end

  ok(updated.with(stream: stream.with(phase: phase)))
end

def send_piece(state: Progress, body: Bytes, deadline: Int) -> Result[Progress]
  sent = try send_data(state, body, deadline)
  return ok(sent.with(stream: sent.stream.with(phase: StreamPhase.HalfClosedLocal))) if sent.stream.sent == body.size

  ok(sent)
end

def can_send?(state: Progress, size: Int) -> Bool = can_upload?(state, size)

def reset(session: Session, id: Int, code: Int, deadline: Int) -> Result[Void]
  send(session, 3, 0, id, Frame.word(code), deadline)
end

def response(stream: Stream) -> Response
  Response(status: stream.status, headers: stream.fields, body: Bytes.concat(stream.parts))
end

def dispatch_closed(session: Session, frame: Frame.Frame, stream: Stream, deadline: Int) -> Result[Progress]
  if frame.kind == 0
    credit = session.receive_credit - frame.payload.size
    return Frame.invalid("incoming connection window exhausted") if credit < 0
    if credit <= REFILL and session.write_error.none?
      try send(session, 8, 0, 0, Frame.word(WINDOW - credit), deadline)
      credit = WINDOW
    end

    return ok(Progress(session: session.with(receive_credit: credit), stream: stream))
  end

  return discard_headers(session, frame, stream) if frame.kind == 1 or frame.kind == 9

  changed = try dispatch(session, frame, deadline)
  ok(Progress(session: changed, stream: stream))
end

def length_valid?(stream: Stream, method: String) -> Bool
  return true if bodyless?(method, stream.status)
  case stream.expected_size
    some(size) -> stream.received <= size and (not stream.ended or stream.received == size)
    none -> true
  end
end

private

EMPTY = "".bytes
WINDOW = 65_535
REFILL = 32_768

def can_upload?(state: Progress, size: Int) -> Bool
  (
    state.session.write_error.none? and
    state.stream.sent < size and
    state.stream.send_credit > 0 and
    state.session.send_credit > 0
  )
end

def read_available(session: Session, deadline: Int) -> Result[Session]
  ready = session
  while not Frame.pending?(ready.buffer)
    _ = try remaining(deadline)
    case ready.incoming.recv(0)
      ok(bytes) -> ready = ready.with(buffer: ready.buffer + bytes)
      error(_) -> return ok(ready)
    end
  end

  ok(ready)
end

def receive(state: Progress, frame: Frame.Frame, req: Request, deadline: Int) -> Result[Progress]
  stream = state.stream
  if stream.continuing and (frame.kind != 9 or frame.stream != stream.id)
    return Frame.invalid("interrupted header block")
  end

  if frame.stream != stream.id or frame.kind == 2 or frame.kind == 4 or frame.kind == 6 or frame.kind == 7
    next_session = try idle_control(state.session, frame, deadline)
    return closed() if next_session.last_stream < stream.id

    delta = next_session.initial_window - state.session.initial_window
    credit = stream.send_credit + delta
    return Frame.invalid("stream window overflow") if credit > Frame.MAX_WINDOW
    return ok(Progress(session: next_session, stream: stream.with(send_credit: credit)))
  end

  case frame.kind
    0 -> data(state, frame, req, deadline)
    1, 9 -> header_fragment(state, frame)
    3 ->
      return Frame.invalid("invalid rst_stream") if frame.payload.size != 4
      error("http_client: the peer reset stream #{stream.id}", kind: "http_client.network")
    5 -> Frame.invalid("push is disabled")
    8 ->
      credit = try add_credit(stream.send_credit, frame)
      ok(state.with(stream: stream.with(send_credit: credit)))
    _ -> ok(state)
  end
end

def idle_control(session: Session, frame: Frame.Frame, deadline: Int) -> Result[Session]
  case frame.kind
    0, 1, 5, 9 -> Frame.invalid("unexpected stream frame")
    3, 8 if frame.stream > 0 ->
      size = frame.payload.size
      if frame.stream >= session.next_stream or frame.stream % 2 == 0 or size != 4
        return Frame.invalid("invalid frame on inactive stream")
      end

      ok(session)
    _ -> control(session, frame, deadline)
  end
end

def control(session: Session, frame: Frame.Frame, deadline: Int) -> Result[Session]
  case frame.kind
    4 ->
      return Frame.invalid("invalid settings stream") if frame.stream != 0
      if flag?(frame, 1)
        return Frame.invalid("settings ack has a payload") if not frame.payload.empty?
        return ok(session)
      end

      changed = try settings(session, frame.payload)
      ok(acknowledge(changed, frame.with(payload: EMPTY), deadline))
    6 ->
      return Frame.invalid("invalid ping") if frame.stream != 0 or frame.payload.size != 8
      return ok(session) if flag?(frame, 1)
      ok(acknowledge(session, frame, deadline))
    7 ->
      return Frame.invalid("invalid goaway") if frame.stream != 0 or frame.payload.size < 8
      last = Frame.u32(frame.payload, 0).bit_and(Frame.MAX_WINDOW)
      return Frame.invalid("goaway increased the last stream") if last > session.last_stream
      ok(session.with(last_stream: last, draining: true))
    8 ->
      credit = try add_credit(session.send_credit, frame)
      ok(session.with(send_credit: credit))
    2 ->
      return Frame.invalid("invalid priority") if frame.stream == 0 or frame.payload.size != 5
      ok(session)
    3 -> Frame.invalid("invalid rst_stream")
    _ -> ok(session)
  end
end

def acknowledge(session: Session, frame: Frame.Frame, deadline: Int) -> Session
  return session if session.write_error.some?
  case send(session, frame.kind, 1, 0, frame.payload, deadline)
    ok(_) -> session
    error(e) -> session.with(write_error: some(e))
  end
end

def settings(session: Session, bytes: Bytes) -> Result[Session]
  return Frame.invalid("invalid settings length") if bytes.size % 6 != 0
  changed = session
  for i in 0...(bytes.size / 6)
    offset = i * 6
    id = bytes[offset] * 256 + bytes[offset + 1]
    value = Frame.u32(bytes, offset + 2)
    case id
      2 -> return Frame.invalid("invalid server enable_push") if value != 0
      3 -> changed = changed.with(stream_limit: value)
      4 ->
        return Frame.invalid("invalid initial window") if value > Frame.MAX_WINDOW
        changed = changed.with(initial_window: value)
      5 ->
        return Frame.invalid("invalid max frame size") if value < Frame.MAX_PAYLOAD or value > 16_777_215
        changed = changed.with(frame_size: value)
      _ -> nil
    end
  end

  ok(changed)
end

def add_credit(current: Int, frame: Frame.Frame) -> Result[Int]
  return Frame.invalid("invalid window update length") if frame.payload.size != 4
  increment = Frame.u32(frame.payload, 0).bit_and(Frame.MAX_WINDOW)
  return Frame.invalid("invalid window increment") if increment == 0 or current + increment > Frame.MAX_WINDOW
  ok(current + increment)
end

def send_data(state: Progress, body: Bytes, deadline: Int) -> Result[Progress]
  s = state.stream
  c = state.session
  count = [body.size - s.sent, s.send_credit, c.send_credit, c.frame_size, Frame.MAX_PAYLOAD].min.unwrap!
  end_offset = s.sent + count
  flags = 0
  if end_offset == body.size
    flags = 1
  end

  bytes = Frame.encode(0, flags, s.id, body.slice(s.sent, count))
  try write(
    c,
    Write(
      bytes: bytes,
      stream: s.id,
      credit: count,
      deadline: some(deadline),
      cancelled: s.cancelled,
      end_stream: flags == 1,
    ),
    deadline,
  )

  ok(
    Progress(
      session: c.with(send_credit: c.send_credit - count),
      stream: s.with(sent: end_offset, send_credit: s.send_credit - count),
    ),
  )
end

def data(state: Progress, frame: Frame.Frame, req: Request, deadline: Int) -> Result[Progress]
  s = state.stream
  c = state.session
  payload = try unpad(frame, 0)

  size = frame.payload.size
  connection_credit = c.receive_credit - size
  stream_credit = s.receive_credit - size
  return Frame.invalid("incoming flow control window exhausted") if connection_credit < 0 or stream_credit < 0
  if s.status == 0 or (bodyless?(req.method, s.status) and not payload.empty?)
    message = "data before the final response"
    if s.status != 0
      message = "body on a bodyless response"
    end

    discarded = try dispatch_closed(c, frame, s, deadline)
    return ok(discarded.with(malformed: some(message)))
  end

  if payload.size > req.max_body_bytes - s.received
    return error("http_client: response body exceeds its limit", kind: "http_client.too_large")
  end

  ended = flag?(frame, 1)
  next_stream = s.with(ended: ended)
  if not payload.empty?
    next_stream = next_stream.with(parts: s.parts.push(payload), received: s.received + payload.size)
  end

  if connection_credit <= REFILL and c.write_error.none?
    wait = deadline
    if ended
      wait = Time.monotonic_ms() + 1_000
    end

    case send(c, 8, 0, 0, Frame.word(WINDOW - connection_credit), wait)
      ok(_) -> connection_credit = WINDOW
      error(e) -> c = c.with(write_error: some(e))
    end
  end

  if not ended and stream_credit <= REFILL and c.write_error.none?
    case send(c, 8, 0, s.id, Frame.word(WINDOW - stream_credit), deadline)
      ok(_) -> stream_credit = WINDOW
      error(e) -> c = c.with(write_error: some(e))
    end
  end

  ok(
    Progress(
      session: c.with(receive_credit: connection_credit),
      stream: next_stream.with(receive_credit: stream_credit),
    ),
  )
end

def discard_headers(session: Session, frame: Frame.Frame, stream: Stream) -> Result[Progress]
  fragment = try header_bytes(stream, frame)
  if fragment.size > Headers.BLOCK_LIMIT - stream.block.size
    return Frame.invalid("compressed header block exceeds its limit")
  end

  block = stream.block + fragment
  return ok(Progress(session: session, stream: stream.with(block: block, continuing: true))) if not flag?(frame, 4)

  decoded = try Hpack.decode(session.decoder, block)
  ok(Progress(session: session.with(decoder: decoded.state), stream: stream.with(block: EMPTY, continuing: false)))
end

def header_bytes(stream: Stream, frame: Frame.Frame) -> Result[Bytes]
  if frame.kind == 1
    priority = 0
    if flag?(frame, 32)
      priority = 5
    end

    return unpad(frame, priority)
  end

  return Frame.invalid("unexpected continuation") if not stream.continuing
  ok(frame.payload)
end

def header_fragment(state: Progress, frame: Frame.Frame) -> Result[Progress]
  s = state.stream
  fragment = try header_bytes(s, frame)
  ended = s.end_on_headers
  if frame.kind == 1
    ended = flag?(frame, 1)
  end

  if fragment.size > Headers.BLOCK_LIMIT - s.block.size
    return Frame.invalid("compressed header block exceeds its limit")
  end

  block = s.block + fragment
  return ok(state.with(stream: s.with(block: block, continuing: true, end_on_headers: ended))) if not flag?(frame, 4)

  decoded = try Hpack.decode(state.session.decoder, block)
  completed = Progress(
    session: state.session.with(decoder: decoded.state),
    stream: s.with(block: EMPTY, continuing: false, end_on_headers: false),
  )

  case Headers.decode(decoded.headers, s.status > 0)
    error(e) -> ok(completed.with(malformed: some(e.message)))
    ok(head) -> ok(apply_head(completed, head, ended))
  end
end

def apply_head(state: Progress, head: Headers.Head, ended: Bool) -> Progress
  stream = state.stream
  if stream.status > 0
    return state.with(malformed: some("trailers without end_stream")) if not ended
    return state.with(stream: stream.with(ended: true))
  end

  if head.status < 200
    return state.with(malformed: some("invalid informational response")) if ended or head.status == 101
    return state
  end

  state.with(stream: stream.with(status: head.status, fields: head.fields, expected_size: head.length, ended: ended))
end

def bodyless?(method: String, status: Int) -> Bool = method == "HEAD" or status == 204 or status == 304

def send_headers(
  session: Session,
  id: Int,
  block: Bytes,
  empty: Bool,
  deadline: Int,
  cancel: Channel[Bool],
) -> Result[Void]
  offset = 0
  kind = 1
  frames: List[Bytes] = []
  while offset < block.size
    count = [session.frame_size, block.size - offset].min.unwrap!
    flags = 0
    if kind == 1 and empty
      flags = 1
    end

    if offset + count == block.size
      flags = flags + 4
    end

    frames = frames.push(Frame.encode(kind, flags, id, block.slice(offset, count)))
    offset = offset + count
    kind = 9
  end

  write(
    session,
    Write(bytes: Bytes.concat(frames), stream: id, deadline: some(deadline), opening: true, cancelled: some(cancel)),
    deadline,
  )
end

def unpad(frame: Frame.Frame, skip: Int) -> Result[Bytes]
  bytes = frame.payload
  if flag?(frame, 8)
    return Frame.invalid("missing padding length") if bytes.empty?
    end_offset = bytes.size - bytes[0]
    return Frame.invalid("invalid frame padding") if end_offset < 1 + skip
    return ok(bytes.slice(1 + skip, end_offset - 1 - skip))
  end

  return Frame.invalid("truncated frame payload") if bytes.size < skip
  ok(bytes.drop(skip))
end

def read_frame(session: Session, deadline: Int) -> Result[Read]
  buffer = session.buffer
  while true
    _ = try remaining(deadline)
    case try Frame.parse(buffer)
      some(parsed) -> return ok(Read(frame: parsed.frame, session: session.with(buffer: parsed.rest)))
      none -> nil
    end

    bytes = try read_chunk(session, deadline)
    buffer = buffer + bytes
  end

  closed()
end

def read_chunk(session: Session, deadline: Int) -> Result[Bytes]
  case session.incoming.recv(try remaining(deadline))
    ok(bytes) -> ok(bytes)
    error(e) if e.is_a?("channel.closed") -> closed()
    error(_) -> error("http_client: HTTP/2 read timed out", kind: "net.timeout")
  end
end

def send(session: Session, kind: Int, flags: Int, id: Int, bytes: Bytes, deadline: Int) -> Result[Void]
  write(session, Write(bytes: Frame.encode(kind, flags, id, bytes), stream: id, reset: kind == 3), deadline)
end

def write(session: Session, item: Write, deadline: Int) -> Result[Void]
  case session.writer
    some(writer) -> writer.send(item, 0)
    none -> TCP.send_bytes(session.socket, item.bytes, try remaining(deadline))
  end
end

def remaining(deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  return error("http_client: HTTP/2 operation timed out", kind: "net.timeout") if left < 1
  ok(left)
end

def flag?(frame: Frame.Frame, flag: Int) -> Bool = frame.flags.bit_and(flag) != 0

def closed[T]() -> Result[T] = error("http_client: the HTTP/2 session is closed", kind: "net.closed")

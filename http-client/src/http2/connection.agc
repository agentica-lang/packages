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
  stream_limit: Int = 1
  last_stream: Int = 0x7fffffff
  draining: Bool = false
  control_pending: Bool = false
  write_error: Optional[Error] = none
end

struct Answer
  response: Response
  session: Session
end

struct Submission
  request: Request
  connect_timeout_ms: Int
  reply: Channel[Result[Response]]
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

def idle(session: Session, deadline: Int, frame_budget: Int = 32) -> Result[Session]
  active = session
  processed = 0
  while reusable?(active) and processed < frame_budget
    _ = try remaining(deadline)
    case try Frame.parse(active.buffer)
      some(parsed) ->
        active = try idle_control(active.with(buffer: parsed.rest), parsed.frame, deadline)
        processed = processed + 1
      none ->
        case active.incoming.recv(0)
          ok(bytes) -> active = active.with(buffer: active.buffer + bytes)
          error(e) if e.is_a?("channel.closed") -> return closed()
          error(_) -> return ok(active.with(control_pending: false))
        end
    end
  end

  ok(active.with(control_pending: reusable?(active)))
end

def request(session: Session, req: Request, block: Bytes, head_deadline: Int) -> Result[Answer]
  active = try classify_timeout(ready_to_send(session, head_deadline), head_deadline, req.deadline)
  id = active.next_stream
  try classify_timeout(send_headers(active, id, block, req.body.empty?, head_deadline), head_deadline, req.deadline)
  stream = Stream(id: id, send_credit: active.initial_window)
  next_session = active.with(next_stream: id + 2)
  exchange(next_session, stream, req, head_deadline)
end

def classify_timeout[T](result: Result[T], deadline: Int, request_deadline: Int) -> Result[T]
  case result
    error(e) if e.is_a?("net.timeout") and deadline == request_deadline ->
      error("http_client: the request timed out", kind: "http_client.timeout.request", cause: e)
    _ -> result
  end
end

private

EMPTY = "".bytes
WINDOW = 65_535
REFILL = 32_768

struct Read
  frame: Frame.Frame
  session: Session
end

struct Stream
  id: Int
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
end

def ready_to_send(session: Session, deadline: Int) -> Result[Session]
  active = session
  while true
    case idle(active, deadline)
      ok(next_session) -> active = next_session
      error(e) if e.is_a?("net.closed") -> return unsent()
      error(e) -> return error(e)
    end

    case active.write_error
      some(e) if not e.is_a?("net.closed") -> return error(e)
      _ -> nil
    end

    return unsent() if not reusable?(active)
    next if active.control_pending
    return ok(active) if active.stream_limit > 0
    waiting = read_control(active, deadline)
    case waiting
      ok(updated) -> active = updated
      error(e) if e.is_a?("net.closed") -> return unsent()
      error(e) -> return error(e)
    end
  end

  unsent()
end

def read_control(session: Session, deadline: Int) -> Result[Session]
  read = try read_frame(session, deadline)
  idle_control(read.session, read.frame, deadline)
end

def exchange(session: Session, stream: Stream, req: Request, head_deadline: Int) -> Result[Answer]
  state = Progress(session: session, stream: stream)
  body_deadline = req.deadline
  while not state.stream.ended
    current = state.stream
    wait_until = head_deadline
    if current.status > 0
      wait_until = body_deadline
    end

    ready = try classify_timeout(read_available(state.session, wait_until), wait_until, req.deadline)
    state = state.with(session: ready)
    buffered = try Frame.parse(ready.buffer)
    if buffered.none? and can_upload?(state, req.body.size)
      case send_data(state, req.body, wait_until)
        ok(sent) -> state = sent
        error(e) -> state = state.with(session: ready.with(write_error: some(e)))
      end

      next
    end

    read = try classify_timeout(read_response_frame(state.session, wait_until), wait_until, req.deadline)
    state = try receive(Progress(session: read.session, stream: state.stream), read.frame, req, wait_until)
    if req.body_idle_ms > 0 and state.stream.status > 0
      if current.status == 0 or state.stream.received > current.received
        body_deadline = [req.deadline, Time.monotonic_ms() + req.body_idle_ms].min.unwrap!
      end
    end
  end

  finished = state.stream
  session_after_response = state.session
  if finished.sent < req.body.size and reusable?(session_after_response)
    reset = send(session_after_response, 3, 0, finished.id, Frame.word(8), cleanup_deadline(req.deadline))
    if not reset.ok?
      session_after_response = session_after_response.with(draining: true)
    end
  end

  response = Response(status: finished.status, headers: finished.fields, body: Bytes.concat(finished.parts))
  ok(Answer(response: response, session: session_after_response))
end

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
  while (try Frame.parse(ready.buffer)).none?
    _ = try remaining(deadline)
    case ready.incoming.recv(0)
      ok(bytes) -> ready = ready.with(buffer: ready.buffer + bytes)
      error(_) -> return ok(ready)
    end
  end

  ok(ready)
end

def read_response_frame(session: Session, deadline: Int) -> Result[Read]
  case read_frame(session, deadline)
    ok(read) -> ok(read)
    error(e) if e.is_a?("net.closed") -> error(session.write_error.unwrap_or(e))
    error(e) -> error(e)
  end
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
    1, 9 -> header_fragment(state, frame, req.method)
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

  try send(c, 0, flags, s.id, body.slice(s.sent, count), deadline)
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
  return Frame.invalid("data before the final response") if s.status == 0
  payload = try unpad(frame, 0)
  return Frame.invalid("body on a bodyless response") if bodyless?(req.method, s.status) and not payload.empty?

  size = frame.payload.size
  connection_credit = c.receive_credit - size
  stream_credit = s.receive_credit - size
  return Frame.invalid("incoming flow control window exhausted") if connection_credit < 0 or stream_credit < 0
  if payload.size > req.max_body_bytes - s.received
    return error("http_client: response body exceeds its limit", kind: "http_client.too_large")
  end

  ended = flag?(frame, 1)
  next_stream = s.with(ended: ended)
  if not payload.empty?
    next_stream = next_stream.with(parts: s.parts.push(payload), received: s.received + payload.size)
  end

  try check_length(next_stream, req.method)
  if connection_credit <= REFILL and c.write_error.none? and (not ended or reusable?(c))
    wait = deadline
    if ended
      wait = cleanup_deadline(deadline)
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

def cleanup_deadline(deadline: Int) -> Int = [deadline, Time.monotonic_ms() + 10].min.unwrap!

def header_fragment(state: Progress, frame: Frame.Frame, method: String) -> Result[Progress]
  s = state.stream
  fragment = frame.payload
  ended = s.end_on_headers
  if frame.kind == 1
    priority = 0
    if flag?(frame, 32)
      priority = 5
    end

    fragment = try unpad(frame, priority)
    ended = flag?(frame, 1)
  elsif not s.continuing
    return Frame.invalid("unexpected continuation")
  end

  if fragment.size > Headers.BLOCK_LIMIT - s.block.size
    return Frame.invalid("compressed header block exceeds its limit")
  end

  block = s.block + fragment
  return ok(state.with(stream: s.with(block: block, continuing: true, end_on_headers: ended))) if not flag?(frame, 4)

  decoded = try Hpack.decode(state.session.decoder, block)
  head = try Headers.decode(decoded.headers, s.status > 0)
  next_stream = s.with(block: EMPTY, continuing: false, end_on_headers: false)
  if s.status > 0
    return Frame.invalid("trailers without end_stream") if not ended
    next_stream = next_stream.with(ended: true)
  elsif head.status < 200
    return Frame.invalid("invalid informational response") if ended or head.status == 101
  else
    next_stream = next_stream.with(status: head.status, fields: head.fields, expected_size: head.length, ended: ended)
  end

  try check_length(next_stream, method)
  ok(Progress(session: state.session.with(decoder: decoded.state), stream: next_stream))
end

def check_length(stream: Stream, method: String) -> Result[Void]
  if not bodyless?(method, stream.status)
    case stream.expected_size
      some(size) ->
        if stream.received > size or (stream.ended and stream.received != size)
          return Frame.invalid("content-length does not match response body")
        end

      none -> nil
    end
  end

  ok()
end

def bodyless?(method: String, status: Int) -> Bool = method == "HEAD" or status == 204 or status == 304

def send_headers(session: Session, id: Int, block: Bytes, empty: Bool, deadline: Int) -> Result[Void]
  offset = 0
  kind = 1
  while offset < block.size
    count = [session.frame_size, block.size - offset].min.unwrap!
    flags = 0
    if kind == 1 and empty
      flags = 1
    end

    if offset + count == block.size
      flags = flags + 4
    end

    try send(session, kind, flags, id, block.slice(offset, count), deadline)
    offset = offset + count
    kind = 9
  end

  ok()
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
  TCP.send_bytes(session.socket, Frame.encode(kind, flags, id, bytes), try remaining(deadline))
end

def remaining(deadline: Int) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  return error("http_client: HTTP/2 operation timed out", kind: "net.timeout") if left < 1
  ok(left)
end

def flag?(frame: Frame.Frame, flag: Int) -> Bool = frame.flags.bit_and(flag) != 0

def closed[T]() -> Result[T] = error("http_client: the HTTP/2 session is closed", kind: "net.closed")

def unsent[T]() -> Result[T] = error("HTTP/2 session closed before request headers", kind: "http2.unsent")

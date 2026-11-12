## One connection: the socket, the handshake over it, the frames in and out. Each public function is a thin wrapper
## that puts "websocket: " before the reason of an error, so the messages of the pure modules stay plain.
##
## A read takes exactly the bytes that a frame announces, so no byte past the frame is held in the program: the
## connection has no buffer and the `Client` is a plain record. The only bytes read ahead are the socket's own, which
## `TCP.read_line` and `TCP.recv_bytes` share.

import Frame from "frame"
import Handshake from "handshake"
import Types from "types"

# TCP.send_bytes takes at most 1 MiB (1_048_576). A frame goes out in one send so that the frames of tasks that
# write at
# once never mix, which is why a message is capped at what one send holds: 1 MiB less the 14 bytes of the largest head.
MAX_SEND = 1_048_562
READ_BYTES = 1_048_576
# The head of the answer of a server: a longer one is not a handshake.
MAX_HEAD_LINES = 100
MAX_HEAD_BYTES = 16_384
KEY_BYTES = 16
MASK_BYTES = 4

# What reading a frame gave: a frame, the end of the connection, a frame that a check refused, or an I/O error.
enum Step
  Got(Frame.Head, Bytes)
  Ended
  Refused(Frame.Problem)
  Broke(String)
end

export def connect(url: String, options: Types.Options) -> Result[Types.Client]
  case prefixed(open(url, options, false))
    ok(answer) ->
      case answer
        Types.Handshake.Open(client) -> ok(client)
        Types.Handshake.Refused(status, _, _) -> error("websocket: the server answered #{status}, not 101")
      end

    error(reason) -> error(reason)
  end
end

export def handshake(url: String, options: Types.Options) -> Result[Types.Handshake]
  prefixed(open(url, options, true))
end

export def send_data(client: Types.Client, opcode: Int, payload: Bytes) -> Result[Void]
  prefixed(send_frame(client, opcode, payload, MAX_SEND))
end

export def send_control(client: Types.Client, opcode: Int, payload: Bytes) -> Result[Void]
  prefixed(send_frame(client, opcode, payload, Frame.CONTROL_BYTES))
end

export def receive(client: Types.Client) -> Result[Types.Message] = prefixed(read_message(client))

export def close(client: Types.Client, code: Int, reason: String) -> Result[Void]
  prefixed(shut(client, code, reason))
end

def prefixed[T](result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(reason) -> error("websocket: #{reason}")
  end
end

# A deadline is the clock plus a timeout: a timeout past a day would let that sum overflow an Int, and no program waits
# longer than that for a socket.
def check_options(options: Types.Options) -> Result[Void]
  if options.max_message_bytes < 1 or options.timeout_ms < 1 or options.read_timeout_ms < 1
    return error("max_message_bytes and the timeouts must be positive")
  end

  return error("close_timeout_ms must be positive") if options.close_timeout_ms < 1

  limit = Types.MAX_TIMEOUT_MS
  if options.timeout_ms > limit or options.read_timeout_ms > limit or options.close_timeout_ms > limit
    return error("the timeouts are at most #{limit} milliseconds")
  end

  ok()
end

def open(url: String, options: Types.Options, read_body: Bool) -> Result[Types.Handshake]
  try check_options(options)
  target = try Handshake.parse_url(url)
  key = Base64.strict_encode64(OpenSSL.Random.random_bytes(KEY_BYTES))
  request = try Handshake.request(target, key, options.protocols, options.headers)
  socket = try dial(target, options)
  case upgrade(socket, request, key, options, read_body)
    ok(client) -> ok(client)
    error(reason) ->
      TCP.close(socket)
      error(reason)
  end
end

def dial(target: Handshake.Target, options: Types.Options) -> Result[Socket]
  return TCP.connect(target.host, target.port, options.timeout_ms) if not target.secure

  case options.tls
    some(context) -> TLS.connect(target.host, target.port, context, options.timeout_ms)
    none -> TLS.connect(target.host, target.port, try TLS.client_context(TlsClientOptions()), options.timeout_ms)
  end
end

# One deadline covers the sending of the request, the head and (with `read_body`) the body of the answer. A status
# outside 200 to 599 that is not 101 is no final answer: it is an `error` (a 1xx is not skipped). Any other status but
# 101 is a `Refused`, and `connect` (no `read_body`) stops at its head, so it never waits for a body that it drops.
def upgrade(
  socket: Socket,
  request: String,
  key: String,
  options: Types.Options,
  read_body: Bool,
) -> Result[Types.Handshake]
  deadline = Time.monotonic_ms() + options.timeout_ms
  try TCP.send(socket, request, try left(deadline))
  lines = try read_answer(socket, deadline)
  return error("the server sent no answer") if lines.empty?

  status = try Handshake.status_of(lines[0])
  headers = Handshake.headers_of(lines.drop(1))
  if status != Handshake.SWITCHING
    return error("the server answered #{status}, which is not a final status") if status < 200 or status > 599

    body = ""
    if read_body
      body = read_body_of(socket, headers, deadline)
    end

    TCP.close(socket)
    return ok(Types.Handshake.Refused(status, headers, body))
  end

  protocol = try Handshake.check_response(lines, key, options.protocols)
  ok(
    Types.Handshake.Open(
      Types.Client(socket: socket, protocol: protocol, options: options, status: status, headers: headers),
    ),
  )
end

# The start of the body of a refused answer: `Content-Length` bytes, at most `MAX_BODY_BYTES`. The bytes that came
# before the peer closed or the deadline hit are kept; a body that is missing is "". It never fails the call: the
# status and the headers are the answer.
def read_body_of(socket: Socket, headers: List[Header], deadline: Int) -> String
  size = Handshake.content_length(headers, Types.MAX_BODY_BYTES)
  return "" if size < 1

  text_of(read_partial(socket, size, deadline))
end

# Up to `count` bytes, fewer when the peer closes or the deadline comes first.
def read_partial(socket: Socket, count: Int, deadline: Int) -> Bytes
  parts: List[Bytes] = []
  have = 0
  while have < count
    chunk = next_chunk(socket, count - have, deadline)
    break if chunk.empty?

    parts = parts.push(chunk)
    have = have + chunk.size
  end

  Bytes.concat(parts)
end

# The next bytes, or none for the end, a timeout or an error.
def next_chunk(socket: Socket, want: Int, deadline: Int) -> Bytes
  case left(deadline)
    error(_) -> "".bytes
    ok(time) -> TCP.recv_bytes(socket, want, time).unwrap_or("".bytes)
  end
end

# The bytes as text. A body cut in the middle of a character (at the cap, or by the peer) loses that last character;
# bytes that are still not UTF-8 give "".
def text_of(data: Bytes) -> String
  case String.from_bytes(data)
    ok(text) -> return text
    error(_) -> nil
  end

  for back in 1..3
    break if back > data.size

    lead = data.at(data.size - back)
    if lead >= 192
      length = 4
      if lead < 224
        length = 2
      elsif lead < 240
        length = 3
      end

      return "" if length <= back

      return String.from_bytes(data.slice(0, data.size - back)).unwrap_or("")
    end

    return "" if lead < 128
  end

  ""
end

# The lines of the head of the answer, up to the empty line.
def read_answer(socket: Socket, deadline: Int) -> Result[List[String]]
  lines: List[String] = []
  size = 0
  while true
    line = try TCP.read_line(socket, try left(deadline))
    break if line.empty?

    lines = lines.push(line)
    size = size + line.bytes.size
    if size > MAX_HEAD_BYTES or lines.size > MAX_HEAD_LINES
      return error("the answer of the server has a head that is too long")
    end
  end

  ok(lines)
end

def send_frame(client: Types.Client, opcode: Int, payload: Bytes, limit: Int) -> Result[Void]
  return error("a payload of #{payload.size} bytes is too big, at most #{limit}") if payload.size > limit

  key = OpenSSL.Random.random_bytes(MASK_BYTES)
  TCP.send_bytes(client.socket, Frame.encode(opcode, payload, key), client.options.timeout_ms)
end

# The milliseconds until `deadline`. Each wait of a read gets the time that is left, so a server cannot hold a read
# open by sending a byte just before each timeout.
def left(deadline: Int) -> Result[Int]
  time = deadline - Time.monotonic_ms()
  return error("operation timed out") if time < 1

  ok(time)
end

# Bytes exactly as many as asked, or fewer when the server ended the connection first.
def read_exact(socket: Socket, count: Int, deadline: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    want = count - have
    if want > READ_BYTES
      want = READ_BYTES
    end

    chunk = try TCP.recv_bytes(socket, want, try left(deadline))
    break if chunk.empty?

    parts = parts.push(chunk)
    have = have + chunk.size
  end

  ok(Bytes.concat(parts))
end

# One frame, checked, to be read before `deadline`: `held` is what the message has so far.
def read_frame(client: Types.Client, held: Int, deadline: Int) -> Result[Step]
  socket = client.socket
  two = try read_exact(socket, 2, deadline)
  return ok(Step.Ended) if two.size < 2

  first = Frame.head_of(two)
  tail = try read_exact(socket, Frame.tail_size(first), deadline)
  return ok(Step.Ended) if tail.size < Frame.tail_size(first)

  head = Frame.complete(first, tail)
  case Frame.check_head(head, client.options.max_message_bytes, held)
    some(problem) -> return ok(Step.Refused(problem))
    none -> nil
  end

  payload = try read_exact(socket, head.length, deadline)
  return ok(Step.Ended) if payload.size < head.length

  ok(Step.Got(head, payload))
end

def step_of(client: Types.Client, held: Int, deadline: Int) -> Step
  case read_frame(client, held, deadline)
    ok(step) -> step
    error(reason) -> Step.Broke(reason)
  end
end

def read_message(client: Types.Client) -> Result[Types.Message]
  try check_options(client.options)
  assembly = Frame.new_assembly()
  while true
    deadline = Time.monotonic_ms() + client.options.read_timeout_ms
    case step_of(client, assembly.total, deadline)
      Step.Broke(reason) -> return broke(client, reason)
      Step.Ended -> return ended(client)
      Step.Refused(problem) -> return error(reject(client, problem))
      Step.Got(head, payload) ->
        if Frame.control?(head.opcode)
          case try control(client, head, payload)
            some(message) -> return ok(message)
            none -> nil
          end
        else
          case Frame.take(assembly, head, payload, client.options.max_message_bytes)
            Frame.Taken.More(next) -> assembly = next
            Frame.Taken.Whole(text, data) -> return whole(text, data)
            Frame.Taken.Broken(problem) -> return error(reject(client, problem))
          end
        end
    end
  end

  error("the read loop ended")
end

# `Frame.take` checked the UTF-8 of a text, so the decoding cannot fail.
def whole(text: Bool, data: Bytes) -> Result[Types.Message]
  return ok(Types.Message.Binary(data)) if not text

  ok(Types.Message.Text(try String.from_bytes(data)))
end

# A ping is answered at once with its payload; a pong that nobody asked for is not a message; a close is answered with
# its code (RFC 6455 5.5.1) and ends the connection.
def control(client: Types.Client, head: Frame.Head, payload: Bytes) -> Result[Optional[Types.Message]]
  if head.opcode == Frame.PING
    case send_frame(client, Frame.PONG, payload, Frame.CONTROL_BYTES)
      ok(_) -> return ok(none)
      error(reason) ->
        case broke(client, reason)
          ok(message) -> return ok(some(message))
          error(text) -> return error(text)
        end
    end
  end

  return ok(none) if head.opcode == Frame.PONG

  case Frame.parse_close(payload)
    Frame.Closing.Invalid(problem) -> error(reject(client, problem))

    Frame.Closing.Peer(code, reason) ->
      answer = "".bytes
      if code != Frame.CLOSE_NO_STATUS
        answer = Frame.close_payload(code, "").unwrap_or("".bytes)
      end

      _ = send_frame(client, Frame.CLOSE, answer, Frame.CONTROL_BYTES)
      TCP.close(client.socket)
      ok(some(Types.Message.Close(code, reason)))
  end
end

# The end of the connection with no close frame: 1006, as the server of `std/http` tells its sessions.
def ended(client: Types.Client) -> Result[Types.Message]
  TCP.close(client.socket)
  ok(Types.Message.Close(Frame.CLOSE_ABNORMAL, ""))
end

# An I/O error ends the connection and the socket is closed. A timeout is the caller's error; any other (a reset, a
# broken pipe) is a connection that ended with no close frame, 1006. A socket that is closed already (after a close)
# is the caller's error.
def broke(client: Types.Client, reason: String) -> Result[Types.Message]
  return ended(client) if not reason.include?("timed out") and not reason.include?("socket is closed")

  TCP.close(client.socket)
  error(reason)
end

# A frame that broke a rule: the server is told with a close frame of the problem's code, the socket is closed, and
# the reason is the error that the caller gets.
def reject(client: Types.Client, problem: Frame.Problem) -> String
  answer = Frame.close_payload(problem.code, problem.reason).unwrap_or("".bytes)
  _ = send_frame(client, Frame.CLOSE, answer, Frame.CONTROL_BYTES)
  TCP.close(client.socket)
  "protocol error: #{problem.reason}"
end

# The close handshake of the client (RFC 6455 7.1.2): send the close frame, read until the answer of the server, and
# close the socket whatever came. The data that arrives meanwhile is dropped.
def shut(client: Types.Client, code: Int, reason: String) -> Result[Void]
  try check_options(client.options)
  payload = try Frame.close_payload(code, reason)
  case send_frame(client, Frame.CLOSE, payload, Frame.CONTROL_BYTES)
    ok(_) -> await_close(client)
    error(_) -> nil
  end

  TCP.close(client.socket)
  ok()
end

def await_close(client: Types.Client) -> Void
  deadline = Time.monotonic_ms() + client.options.close_timeout_ms
  while true
    case read_frame(client, 0, deadline)
      error(_) -> return
      ok(step) ->
        case step
          Step.Got(head, _) -> return if head.opcode == Frame.CLOSE
          Step.Ended -> return
          Step.Refused(_) -> return
          Step.Broke(_) -> return
        end
    end
  end
end

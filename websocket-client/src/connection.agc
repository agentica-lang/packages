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

# What reading a frame gave: a frame, the end of the connection, or a frame that a check refused.
enum Step
  Got(Frame.Head, Bytes)
  Ended
  Refused(Frame.Problem)
end

export def connect(url: String, options: Types.Options) -> Result[Types.Client] = prefixed(open(url, options))

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

def check_options(options: Types.Options) -> Result[Void]
  if options.max_message_bytes < 1 or options.timeout_ms < 1 or options.read_timeout_ms < 1
    return error("max_message_bytes and the timeouts must be positive")
  end

  return error("close_timeout_ms must be positive") if options.close_timeout_ms < 1

  ok()
end

def open(url: String, options: Types.Options) -> Result[Types.Client]
  try check_options(options)
  target = try Handshake.parse_url(url)
  key = Base64.strict_encode64(OpenSSL.Random.random_bytes(KEY_BYTES))
  request = try Handshake.request(target, key, options.protocols, options.headers)
  socket = try dial(target, options)
  case upgrade(socket, request, key, options)
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

def upgrade(socket: Socket, request: String, key: String, options: Types.Options) -> Result[Types.Client]
  try TCP.send(socket, request, options.timeout_ms)
  lines = try read_answer(socket, options.timeout_ms)
  protocol = try Handshake.check_response(lines, key, options.protocols)
  ok(Types.Client(socket: socket, protocol: protocol, options: options))
end

# The lines of the head of the answer, up to the empty line.
def read_answer(socket: Socket, timeout_ms: Int) -> Result[List[String]]
  lines: List[String] = []
  size = 0
  while true
    line = try TCP.read_line(socket, timeout_ms)
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

# Bytes exactly as many as asked, or fewer when the server ended the connection first.
def read_exact(socket: Socket, count: Int, timeout_ms: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    want = count - have
    if want > READ_BYTES
      want = READ_BYTES
    end

    chunk = try TCP.recv_bytes(socket, want, timeout_ms)
    break if chunk.empty?

    parts = parts.push(chunk)
    have = have + chunk.size
  end

  ok(Bytes.concat(parts))
end

# One frame, checked: `held` is what the message has so far.
def read_frame(client: Types.Client, held: Int, timeout_ms: Int) -> Result[Step]
  socket = client.socket
  two = try read_exact(socket, 2, timeout_ms)
  return ok(Step.Ended) if two.size < 2

  first = Frame.head_of(two)
  tail = try read_exact(socket, Frame.tail_size(first), timeout_ms)
  return ok(Step.Ended) if tail.size < Frame.tail_size(first)

  head = Frame.complete(first, tail)
  case Frame.check_head(head, client.options.max_message_bytes, held)
    some(problem) -> return ok(Step.Refused(problem))
    none -> nil
  end

  payload = try read_exact(socket, head.length, timeout_ms)
  return ok(Step.Ended) if payload.size < head.length

  ok(Step.Got(head, payload))
end

def read_message(client: Types.Client) -> Result[Types.Message]
  assembly = Frame.new_assembly()
  while true
    case try read_frame(client, assembly.total, client.options.read_timeout_ms)
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
    try send_frame(client, Frame.PONG, payload, Frame.CONTROL_BYTES)
    return ok(none)
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
    left = deadline - Time.monotonic_ms()
    return if left < 1

    case read_frame(client, 0, left)
      error(_) -> return
      ok(step) ->
        case step
          Step.Got(head, _) -> return if head.opcode == Frame.CLOSE
          Step.Ended -> return
          Step.Refused(_) -> return
        end
    end
  end
end

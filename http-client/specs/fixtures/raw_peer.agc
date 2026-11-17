## The peer of the scenarios that need a server that misbehaves, or that must say which connection served a request:
## a TCP server on 127.0.0.1 and a free port, which it says on its first line (`listening on PORT`). It reads each
## request by hand (the head up to the empty line, then a `Content-Length` body) and writes the next answer of the
## script, which it got as program arguments, one each. The answers go out in order, whatever the connection; a
## request with no answer left gets a 500.
##
##   ok BODY                a 200 with BODY (`-` is an empty body)
##   status CODE BODY       CODE with BODY
##   close BODY             a 200 with `Connection: close`, and the connection closes after it
##   until-close BODY       a 200 with no length: BODY, then the connection closes
##   stray MS BODY          a 200, then MS later a byte out of turn on the idle connection
##   continue-close         a `100 Continue`, then the connection closes
##   drop                   no answer: the connection closes
##   after CODE SECONDS     CODE with `Retry-After: SECONDS` and an empty body
##   keep-alive SECONDS BODY  a 200 with `Keep-Alive: timeout=SECONDS`
##   slow-head MS BODY      waits MS before it writes the head of a 200
##   stall MS BODY          writes the head of a 200 and half of BODY, waits MS, then writes the rest
##   chunks MS P1,P2,...    a 200 of `text/event-stream`, chunked, with each piece as a chunk and MS between them;
##                          in a piece `_` is a space and `\n` a line end
##   repeat MS COUNT PIECE  as `chunks`, with COUNT times the one PIECE
##   hold P1,P2,...         as `chunks`, but with no wait: it writes the head and P1, then holds the rest until a request
##                          to `/release` comes (up to HOLD_MS, then the connection closes), so that a client that
##                          buffers P1 until more data comes never gets it and never releases
##   idle MS                not an answer: a connection idle for MS between requests is closed (else it stays)
##
## Each answer has `x-connection: N`, the number of its TCP connection from 1, and the peer prints
## `request N METHOD TARGET` for each request it reads, except `/release`, which is no request of the script: it gets
## an empty 200 and lets a `hold` go on. It is written apart from std/http on purpose: it is the peer's
## own reading of HTTP/1.1.

private

DEFAULT_IDLE_MS = 3_600_000
STEP_MS = 10_000
HOLD_MS = 15_000
CRLF = "\r\n"

struct Request
  method: String
  target: String
end

struct Setup
  idle_ms: Int
  answers: Channel[List[String]]
  released: Channel[Bool]
end

# One accepted connection, which its task owns.
struct Conn
  socket: TCP.Socket
  number: Int
  setup: Setup
end

def main() -> Void
  setup = read_script(System.args())
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  puts("listening on #{TCP.local_port(listener)}")
  IO.flush()
  number = 0
  while true
    case TCP.accept(listener, 3_600_000)
      ok(socket) ->
        number = number + 1
        # Only the socket is handed over: the channel of the answers stays shared.
        served = number
        Task.spawn_owning(->(owned) { serve(Conn(socket: owned, number: served, setup: setup)) }, socket)
      error(_) -> nil
    end
  end
end

def read_script(args: List[String]) -> Setup
  idle_ms = DEFAULT_IDLE_MS
  answers: Channel[List[String]] = Channel.new([args.size, 1].max.unwrap!)
  released: Channel[Bool] = Channel.new(16)
  for line in args
    words = line.strip.split(" ")
    if words[0] == "idle"
      idle_ms = words[1].to_i!
    else
      answers.send(words, 0).unwrap!
    end
  end

  Setup(idle_ms: idle_ms, answers: answers, released: released)
end

def serve(conn: Conn) -> Void
  while true
    case read_request(conn.socket, conn.setup.idle_ms)
      ok(request) if request.target == "/release" ->
        _ = conn.setup.released.send(true, 0)
        head = "HTTP/1.1 200 Peer#{CRLF}x-connection: #{conn.number}#{CRLF}content-length: 0#{CRLF}#{CRLF}"
        break if not TCP.send(conn.socket, head, STEP_MS).ok?
      ok(request) ->
        puts("request #{conn.number} #{request.method} #{request.target}")
        IO.flush()
        answer = conn.setup.answers.recv(0).unwrap_or(["status", "500", "no-answer"])
        break if not write_answer(conn.socket, conn.number, request, answer, conn.setup.released)
      error(_) -> break
    end
  end

  TCP.close(conn.socket)
end

def read_request(socket: TCP.Socket, idle_ms: Int) -> Result[Request]
  first = try TCP.read_line(socket, idle_ms)
  parts = first.strip.split(" ")
  return error("bad request line") if parts.size < 2

  length = 0
  while true
    line = try TCP.read_line(socket, STEP_MS)
    break if line.strip.empty?

    if line.downcase.start_with?("content-length:")
      length = try line.slice(15, line.length - 15).strip.to_i
    end
  end

  if length > 0
    _ = try read_exact(socket, length)
  end

  ok(Request(method: parts[0], target: parts[1]))
end

def read_exact(socket: TCP.Socket, count: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    chunk = try TCP.recv_bytes(socket, count - have, STEP_MS)
    return error("the client closed") if chunk.empty?

    parts = parts.push(chunk)
    have = have + chunk.size
  end

  ok(Bytes.concat(parts))
end

def chunked(socket: TCP.Socket, number: Int, wait_ms: Int, pieces: List[String]) -> Bool
  # The head goes in one write with the first piece: a write of its own could hold that piece back until the client
  # acknowledges the head (Nagle), and the first two pieces would come as one.
  before = stream_head(number)
  for piece in pieces
    text = piece.replace("_", " ").replace("\\n", "\n")
    return false if not TCP.send(socket, "#{before}#{format("%x", text.bytesize)}#{CRLF}#{text}#{CRLF}", STEP_MS).ok?

    before = ""
    Task.sleep(wait_ms)
  end

  TCP.send(socket, "0#{CRLF}#{CRLF}", STEP_MS).ok?
end

# The head and the first piece, then, once a request to `/release` came, the other pieces and the end in one write.
# A release that does not come in HOLD_MS ends the connection with the answer cut short.
def held(socket: TCP.Socket, number: Int, pieces: List[String], released: Channel[Bool]) -> Bool
  return false if not TCP.send(socket, "#{stream_head(number)}#{chunk(pieces[0])}", STEP_MS).ok?
  return false if not released.recv(HOLD_MS).ok?

  rest = pieces.drop(1).map { |piece| chunk(piece) }.join("")
  TCP.send(socket, "#{rest}0#{CRLF}#{CRLF}", STEP_MS).ok?
end

def stream_head(number: Int) -> String
  lines = [
    "HTTP/1.1 200 Peer",
    "x-connection: #{number}",
    "content-type: text/event-stream",
    "transfer-encoding: chunked",
  ]

  "#{lines.join(CRLF)}#{CRLF}#{CRLF}"
end

def chunk(piece: String) -> String
  text = piece.replace("_", " ").replace("\\n", "\n")
  "#{format("%x", text.bytesize)}#{CRLF}#{text}#{CRLF}"
end

# Writes the answer and says whether the connection stays open.
def write_answer(
  socket: TCP.Socket,
  number: Int,
  request: Request,
  answer: List[String],
  released: Channel[Bool],
) -> Bool
  op = answer[0]
  declared = answer.last
  if declared == "-"
    declared = ""
  end

  body = declared
  if request.method == "HEAD"
    body = ""
  end

  status = 200
  extra = ""
  wait_ms = 0
  case op
    "status" -> status = answer[1].to_i!
    "close" -> extra = "connection: close"
    "keep-alive" -> extra = "keep-alive: timeout=#{answer[1]}"
    "slow-head" -> wait_ms = answer[1].to_i!
    "stall" -> wait_ms = answer[1].to_i!
    "stray" -> wait_ms = answer[1].to_i!
    "after" ->
      status = answer[1].to_i!
      extra = "retry-after: #{answer[2]}"
      declared = ""
      body = ""
    _ -> nil
  end

  if op == "slow-head"
    Task.sleep(wait_ms)
  end

  return chunked(socket, number, answer[1].to_i!, answer[2].split(",")) if op == "chunks"
  return chunked(socket, number, answer[1].to_i!, (1..answer[2].to_i!).map { |_| answer[3] }) if op == "repeat"
  return held(socket, number, answer[1].split(","), released) if op == "hold"

  return false if op == "drop"

  if op == "continue-close"
    _ = TCP.send(socket, "HTTP/1.1 100 Continue#{CRLF}#{CRLF}", STEP_MS)
    return false
  end

  lines = ["HTTP/1.1 #{status} Peer", "x-connection: #{number}"]
  if op != "until-close"
    lines = lines.push("content-length: #{declared.bytesize}")
  end

  if not extra.empty?
    lines = lines.push(extra)
  end

  head = "#{lines.join(CRLF)}#{CRLF}#{CRLF}"

  if op == "stall"
    half = body.length / 2
    return false if not TCP.send(socket, "#{head}#{body.slice(0, half)}", STEP_MS).ok?

    Task.sleep(wait_ms)
    return TCP.send(socket, body.slice(half, body.length - half), STEP_MS).ok?
  end

  return false if not TCP.send(socket, "#{head}#{body}", STEP_MS).ok?

  if op == "stray"
    Task.sleep(wait_ms)
    return TCP.send(socket, "X", STEP_MS).ok?
  end

  op != "close" and op != "until-close"
end

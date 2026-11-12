## The peer of the scenarios that need bytes that no real server writes: a TCP server on 127.0.0.1 and a free port,
## which it says on its first line (`listening on PORT`). It accepts one client, answers its WebSocket handshake, and
## then runs the script that it got as program arguments, one operation each:
##
##   handshake MODE [ARG]  first, and optional: ok (the default), drip MS (the answer one byte at a time, MS apart),
##                         protocol NAME, status CODE, bad-accept,
##                         missing-upgrade, extension or mixed-case (header names and tokens in odd case)
##   send HEX              writes these bytes (spaces in HEX are ignored); the first `send` goes out in the same write
##                         as the answer to the handshake, so a frame that comes with it is always there at once
##   drip MS HEX           writes these bytes one at a time, MS milliseconds apart
##   fill BYTE SIZE        writes one whole frame (BYTE is its first byte in hex) of SIZE bytes "x", with the
##                         shortest length form
##   host                  prints `host=` and the Host header of the handshake
##   expect                reads one frame of the client and prints `frame op=N fin=B masked=B payload=HEX`
##   expect-keys N         reads N frames and prints `masks distinct=K`, the number of different mask keys
##   sleep MS              waits
##   wait                  reads until the client closes its end
##   close                 closes the socket
##
## The frame parser here is written apart from the package on purpose: it is the peer's own reading of RFC 6455.

import Binary from "std/binary"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
STEP_MS = 10_000
KEY_HEADER = "sec-websocket-key:"
HOST_HEADER = "host:"

struct Frame
  op: Int
  fin: Bool
  masked: Bool
  key: Bytes
  payload: Bytes
end

# What the handshake request said that the script may print.
struct Request
  key: String
  host: String
end

def read_exact(socket: Socket, count: Int) -> Result[Bytes]
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

def read_request(socket: Socket) -> Result[Request]
  key = ""
  host = ""
  while true
    line = try TCP.read_line(socket, STEP_MS)
    break if line.empty?

    if line.downcase.start_with?(KEY_HEADER)
      key = line.slice(KEY_HEADER.length, line.length - KEY_HEADER.length).strip
    elsif line.downcase.start_with?(HOST_HEADER)
      host = line.slice(HOST_HEADER.length, line.length - HOST_HEADER.length).strip
    end
  end

  ok(Request(key: key, host: host))
end

def accept_of(key: String) -> String = Base64.strict_encode64(OpenSSL.Digest.sha1("#{key}#{GUID}".bytes))

def answer(mode: List[String], key: String) -> String
  accept = accept_of(key)
  head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  case mode[0]
    "bad-accept" -> "#{head}Sec-WebSocket-Accept: #{accept_of("another key")}\r\n\r\n"
    "missing-upgrade" ->
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    "mixed-case" ->
      (
        "HTTP/1.1 101 Switching Protocols\r\nUPGRADE: WebSocket\r\nconnection: keep-alive, UPGRADE\r\n" +
        "SEC-WEBSOCKET-ACCEPT: #{accept}\r\n\r\n"
      )
    "extension" -> "#{head}Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"
    "protocol" -> "#{head}Sec-WebSocket-Accept: #{accept}\r\nSec-WebSocket-Protocol: #{mode[1]}\r\n\r\n"
    "status" -> "HTTP/1.1 #{mode[1]} Refused\r\nContent-Length: 0\r\n\r\n"
    _ -> "#{head}Sec-WebSocket-Accept: #{accept}\r\n\r\n"
  end
end

def read_frame(socket: Socket) -> Result[Frame]
  head = try read_exact(socket, 2)
  length = head[1] % 128
  if length == 126
    length = try Binary.read_u16_be(try read_exact(socket, 2), 0)
  end

  if length == 127
    length = try Binary.read_u64_be(try read_exact(socket, 8), 0)
  end

  masked = head[1] >= 128
  key = "".bytes
  if masked
    key = try read_exact(socket, 4)
  end

  data = try read_exact(socket, length)
  payload = data
  if masked
    mask = key.to_a
    plain: List[Int] = []
    place = 0
    for byte in data
      plain = plain.push(Int.bit_xor(byte, mask[place % 4]))
      place = place + 1
    end

    payload = Bytes.from_list(plain).unwrap!
  end

  ok(Frame(op: head[0] % 16, fin: head[0] >= 128, masked: masked, key: key, payload: payload))
end

def hex_of(op: List[String]) -> Result[Bytes] = OpenSSL.Digest.hexdecode(op.join("").replace(" ", ""))

# A whole frame of `size` bytes "x", with the shortest form of the length.
def filled(first: Bytes, size: Int) -> Bytes
  payload = ("x" * size).bytes
  return Bytes.concat([first, Bytes.from_list([size]).unwrap!, payload]) if size < 126

  if size < 65_536
    return Bytes.concat([first, Bytes.from_list([126]).unwrap!, Binary.write_u16_be(size).unwrap!, payload])
  end

  Bytes.concat([first, Bytes.from_list([127]).unwrap!, Binary.write_i64_be(size), payload])
end

def drip(socket: Socket, pause_ms: Int, data: Bytes) -> Result[Void]
  for byte in data
    try TCP.send_bytes(socket, Bytes.from_list([byte]).unwrap!, STEP_MS)
    Task.sleep(pause_ms)
  end

  ok()
end

def distinct_keys(socket: Socket, count: Int) -> Result[Void]
  keys: Set[Bytes] = Set.new([])
  for _round in 1..count
    frame = try read_frame(socket)
    keys = keys.add(frame.key)
  end

  puts("masks distinct=#{keys.size}")
  IO.flush()
  ok()
end

def play(socket: Socket, request: Request, op: List[String]) -> Result[Void]
  case op[0]
    "send" -> try TCP.send_bytes(socket, try hex_of(op.drop(1)), STEP_MS)
    "drip" -> try drip(socket, try op[1].to_i, try hex_of(op.drop(2)))
    "fill" -> try TCP.send_bytes(socket, filled(try hex_of([op[1]]), try op[2].to_i), STEP_MS)
    "host" ->
      puts("host=#{request.host}")
      IO.flush()
    "expect" ->
      frame = try read_frame(socket)
      payload = OpenSSL.Digest.hexencode(frame.payload)
      puts("frame op=#{frame.op} fin=#{frame.fin} masked=#{frame.masked} payload=#{payload}")
      IO.flush()
    "expect-keys" -> try distinct_keys(socket, try op[1].to_i)
    "sleep" -> Task.sleep(try op[1].to_i)
    "wait" ->
      while true
        chunk = try TCP.recv_bytes(socket, 4096, STEP_MS)
        break if chunk.empty?
      end

    "close" -> TCP.close(socket)
    _ -> return error("unknown operation #{op[0]}")
  end

  ok()
end

def run(listener: Listener, script: List[List[String]]) -> Result[Void]
  socket = try TCP.accept(listener, STEP_MS)
  request = try read_request(socket)
  mode = ["ok"]
  steps = script
  if not script.empty? and script[0][0] == "handshake"
    mode = script[0].drop(1)
    steps = script.drop(1)
  end

  answered = answer(mode, request.key).bytes
  if mode[0] == "drip"
    try drip(socket, try mode[1].to_i, answered)
  elsif not steps.empty? and steps[0][0] == "send"
    # The 101 and the first frame in one write: the client must keep the bytes that follow its head.
    try TCP.send_bytes(socket, answered + try hex_of(steps[0].drop(1)), STEP_MS)
    steps = steps.drop(1)
  else
    try TCP.send_bytes(socket, answered, STEP_MS)
  end

  for op in steps
    try play(socket, request, op)
  end

  ok()
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  puts("listening on #{TCP.local_port(listener)}")
  IO.flush()
  script = System.args().map do |line| line.split(" ") end
  case run(listener, script)
    ok(_) -> nil
    error(reason) -> IO.warn("raw peer: #{reason}")
  end
end

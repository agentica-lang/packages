## The peer of the scenarios that need bytes that no real server writes: a TCP server on 127.0.0.1 and a free port,
## which it says on its first line (`listening on PORT`). It accepts one client, answers its WebSocket handshake, and
## then runs the script that it got as program arguments, one operation each:
##
##   handshake MODE [ARG]  first, and optional: ok (the default), protocol NAME, status CODE, bad-accept,
##                         missing-upgrade or extension
##   send HEX              writes these bytes (spaces in HEX are ignored)
##   expect                reads one frame of the client and prints `frame op=N fin=B masked=B payload=HEX`
##   sleep MS              waits
##   wait                  reads until the client closes its end
##   close                 closes the socket
##
## The frame parser here is written apart from the package on purpose: it is the peer's own reading of RFC 6455.

import Binary from "std/binary"

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
STEP_MS = 10_000
KEY_HEADER = "sec-websocket-key:"

struct Frame
  op: Int
  fin: Bool
  masked: Bool
  payload: Bytes
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

def read_request(socket: Socket) -> Result[String]
  key = ""
  while true
    line = try TCP.read_line(socket, STEP_MS)
    break if line.empty?

    if line.downcase.start_with?(KEY_HEADER)
      key = line.slice(KEY_HEADER.length, line.length - KEY_HEADER.length).strip
    end
  end

  ok(key)
end

def accept_of(key: String) -> String = Base64.strict_encode64(OpenSSL.Digest.sha1("#{key}#{GUID}".bytes))

def answer(mode: List[String], key: String) -> String
  accept = accept_of(key)
  head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  case mode[0]
    "bad-accept" -> "#{head}Sec-WebSocket-Accept: #{accept_of("another key")}\r\n\r\n"
    "missing-upgrade" ->
      "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
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

  ok(Frame(op: head[0] % 16, fin: head[0] >= 128, masked: masked, payload: payload))
end

def play(socket: Socket, op: List[String]) -> Result[Bool]
  case op[0]
    "send" -> try TCP.send_bytes(socket, try OpenSSL.Digest.hexdecode(op.drop(1).join("").replace(" ", "")), STEP_MS)
    "expect" ->
      frame = try read_frame(socket)
      payload = OpenSSL.Digest.hexencode(frame.payload)
      puts("frame op=#{frame.op} fin=#{frame.fin} masked=#{frame.masked} payload=#{payload}")
      IO.flush()
    "sleep" -> Task.sleep(try op[1].to_i)
    "wait" ->
      while true
        chunk = try TCP.recv_bytes(socket, 4096, STEP_MS)
        break if chunk.empty?
      end

    "close" -> TCP.close(socket)
    _ -> return error("unknown operation #{op[0]}")
  end

  ok(true)
end

def run(listener: Listener, script: List[List[String]]) -> Result[Void]
  socket = try TCP.accept(listener, STEP_MS)
  key = try read_request(socket)
  mode = ["ok"]
  steps = script
  if not script.empty? and script[0][0] == "handshake"
    mode = script[0].drop(1)
    steps = script.drop(1)
  end

  try TCP.send(socket, answer(mode, key), STEP_MS)
  for op in steps
    try play(socket, op)
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

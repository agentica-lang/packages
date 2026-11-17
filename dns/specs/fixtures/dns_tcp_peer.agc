## The peer of the transport scenarios: a nameserver that answers with the bytes that a script says, so a scenario can
## send what no real server sends. It listens on 127.0.0.1 and a free port, which it says on its first line
## (`listening on PORT`), over TCP, or over TLS when the environment variables `TLS_CERT` and `TLS_KEY` (PEM files) are
## set. It does not use the codec of the package: it only cuts the query in the parts that a script may put in an answer.
## The script is the program arguments, one operation each:
##
##   accept                  closes the client and waits for the next one (the first client is accepted at the start)
##   read                    reads one query (the 2-byte length and the message) and prints `query HEX`, with `ID`
##                           for its first two bytes, so that the line does not depend on the random id
##   send HEX                writes a message with its 2-byte length in front
##   raw HEX                 writes the bytes as they are (a wrong length, a cut answer)
##   split N MS HEX          writes a message with its length as `send`, but in two writes, N bytes and the rest, MS
##                           milliseconds apart
##   drip MS HEX             writes a message with its length one byte at a time, MS milliseconds apart
##   sleep MS                waits
##   close                   closes the client
##
## In a HEX the words are joined (spaces are ignored) and these words stand for bytes of the query that was read last:
## `ID` (its id), `OTHERID` (another id) and `QUESTION` (the question section).

import Binary from "std/binary"

private

STEP_MS = 10_000
HEADER_BYTES = 12

# What the last query said, as hex.
struct Query
  id: String = ""
  other: String = ""
  question: String = ""
end

def read_exact(socket: TCP.Socket, count: Int) -> Result[Bytes]
  parts: List[Bytes] = []
  have = 0
  while have < count
    chunk = try TCP.recv_bytes(socket, count - have, STEP_MS)
    return error("the client closed") if chunk.empty?

    parts = parts.push(chunk)
    have += chunk.size
  end

  ok(Bytes.concat(parts))
end

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def read_query(socket: TCP.Socket) -> Result[Query]
  size = try Binary.read_u16_be(try read_exact(socket, 2), 0)
  data = try read_exact(socket, size)
  id = try Binary.read_u16_be(data, 0)
  other = hex(try Binary.write_u16_be((id + 1) % 65_536))
  puts("query ID#{hex(data.drop(2))}")
  IO.flush()
  ok(Query(id: hex(data.take(2)), other: other, question: hex(data.drop(HEADER_BYTES))))
end

def word(query: Query, text: String) -> String
  case text
    "ID" -> query.id
    "OTHERID" -> query.other
    "QUESTION" -> query.question
    _ -> text
  end
end

def bytes_of(query: Query, words: List[String]) -> Result[Bytes]
  OpenSSL.Digest.hexdecode(words.map { |w| word(query, w) }.join("").replace(" ", ""))
end

def framed(data: Bytes) -> Result[Bytes] = ok(Bytes.concat([try Binary.write_u16_be(data.size), data]))

def drip(socket: TCP.Socket, pause_ms: Int, data: Bytes) -> Result[Void]
  for byte in data
    try TCP.send_bytes(socket, Bytes.from_list([byte]).unwrap!, STEP_MS)
    Task.sleep(pause_ms)
  end

  ok()
end

def play(socket: TCP.Socket, query: Query, op: List[String]) -> Result[Void]
  case op[0]
    "send" -> try TCP.send_bytes(socket, try framed(try bytes_of(query, op.drop(1))), STEP_MS)
    "raw" -> try TCP.send_bytes(socket, try bytes_of(query, op.drop(1)), STEP_MS)
    "split" ->
      data = try framed(try bytes_of(query, op.drop(3)))
      cut = try op[1].to_i
      try TCP.send_bytes(socket, data.take(cut), STEP_MS)
      Task.sleep(try op[2].to_i)
      try TCP.send_bytes(socket, data.drop(cut), STEP_MS)
    "drip" -> try drip(socket, try op[1].to_i, try framed(try bytes_of(query, op.drop(2))))
    "sleep" -> Task.sleep(try op[1].to_i)
    "close" -> TCP.close(socket)
    _ -> return error("unknown operation #{op[0]}")
  end

  ok()
end

def run(listener: TCP.Listener, script: List[List[String]]) -> Result[Void]
  socket = try TCP.accept(listener, STEP_MS)
  query = Query()
  for op in script
    if op[0] == "accept"
      TCP.close(socket)
      socket = try TCP.accept(listener, STEP_MS)
      query = Query()
    elsif op[0] == "read"
      query = try read_query(socket)
    else
      try play(socket, query, op)
    end
  end

  TCP.close(socket)
  ok()
end

def listener_of() -> Result[TCP.Listener]
  case System.env("TLS_CERT")
    ok(cert) ->
      context = try TLS.server_context(TLS.ServerOptions(cert_file: cert, key_file: try System.env("TLS_KEY")))
      TLS.listen("127.0.0.1", 0, context)
    error(_) -> TCP.listen("127.0.0.1", 0)
  end
end

def main() -> Void
  listener = listener_of().unwrap!
  puts("listening on #{TCP.local_port(listener)}")
  IO.flush()
  script = System.args().map { |line| line.split(" ") }
  case run(listener, script)
    ok(_) -> nil
    error(e) -> IO.warn("dns peer: #{e.message}")
  end
end

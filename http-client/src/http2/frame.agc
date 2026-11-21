MAX_PAYLOAD = 16_384
MAX_WINDOW = 0x7fffffff

struct Frame
  kind: Int
  flags: Int
  stream: Int
  payload: Bytes
end

struct Parsed
  frame: Frame
  rest: Bytes
end

def parse(buffer: Bytes) -> Result[Optional[Parsed]]
  return ok(none) if buffer.size < 9
  size = buffer[0] * 65536 + buffer[1] * 256 + buffer[2]
  return invalid("frame exceeds the advertised maximum") if size > MAX_PAYLOAD
  return ok(none) if buffer.size < size + 9
  frame = Frame(
    kind: buffer[3],
    flags: buffer[4],
    stream: u32(buffer, 5).bit_and(MAX_WINDOW),
    payload: buffer.slice(9, size),
  )

  ok(some(Parsed(frame: frame, rest: buffer.drop(9 + size))))
end

def encode(kind: Int, flags: Int, stream: Int, payload: Bytes) -> Bytes
  size = payload.size
  head = Bytes.from_list([
    size.shift_right(16),
    size.shift_right(8).bit_and(255),
    size.bit_and(255),
    kind,
    flags,
    stream.shift_right(24),
    stream.shift_right(16).bit_and(255),
    stream.shift_right(8).bit_and(255),
    stream.bit_and(255),
  ]).unwrap!

  head + payload
end

def u32(data: Bytes, at: Int) -> Int
  data[at] * 16_777_216 + data[at + 1] * 65_536 + data[at + 2] * 256 + data[at + 3]
end

def word(value: Int) -> Bytes
  Bytes.from_list([
    value.shift_right(24),
    value.shift_right(16).bit_and(255),
    value.shift_right(8).bit_and(255),
    value.bit_and(255),
  ]).unwrap!
end

def invalid[T](message: String) -> Result[T] = error("http_client: #{message}", kind: "http_client.http2.protocol")

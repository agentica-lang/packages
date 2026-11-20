import Frame from "frame"
import Hpack from "pkg/hpack/hpack"
import HTTP from "std/http"
import Url from "../url"

BLOCK_LIMIT = 65_536

struct Head
  status: Int = 0
  fields: List[HTTP.Header] = []
  length: Optional[Int] = none
end

def decode(fields: List[Hpack.Header], trailers: Bool) -> Result[Head]
  head = Head()
  for field in fields
    name = try field.name.decode("ascii")
    value = try field.value.decode("latin-1")
    if name == ":status"
      if trailers or head.status != 0 or not head.fields.empty? or value.size != 3
        return Frame.invalid("unexpected status pseudo-header")
      end

      status = try decimal(value)
      return Frame.invalid("invalid response status") if status < 100 or status > 599
      head = head.with(status: status)
    else
      if not token?(field.name) or not field_value?(field.value) or CONNECTION_FIELDS.include?(name)
        return Frame.invalid("invalid response header")
      end

      if name == "content-length"
        length = try decimal(value)
        if trailers or (head.length.some? and head.length.unwrap! != length)
          return Frame.invalid("invalid response content-length")
        end

        head = head.with(length: some(length))
      end

      head = head.with(fields: head.fields.push(HTTP.Header(name: name, value: value)))
    end
  end

  return Frame.invalid("missing response status") if not trailers and head.status == 0
  ok(head)
end

def encode(method: String, target: Url.Target, fields: List[HTTP.Header], body_size: Int) -> Result[Bytes]
  return argument("invalid HTTP/2 method") if not token?(method.downcase.bytes) or method.upcase == "CONNECT"

  return argument("invalid HTTP/2 request target") if not field_value?(target.target.bytes)

  authority = target.origin.bytes.drop(target.scheme.size + 3)
  headers = [
    Hpack.Header(name: ":method".bytes, value: method.bytes),
    Hpack.Header(name: ":scheme".bytes, value: target.scheme.bytes),
    Hpack.Header(name: ":authority".bytes, value: authority),
    Hpack.Header(name: ":path".bytes, value: target.target.bytes),
  ]

  for field in fields
    name = field.name.downcase
    value = field.value.bytes
    if not token?(name.bytes) or not field_value?(value) or CONNECTION_FIELDS.include?(name)
      return argument("invalid HTTP/2 request header")
    end

    next if name == "host"
    if name == "content-length"
      return argument("content-length does not match request body") if field.value != body_size.to_s
      next
    end

    return argument("invalid HTTP/2 te header") if name == "te" and field.value.downcase != "trailers"
    headers = headers.push(Hpack.Header(name: name.bytes, value: value, never_indexed: SENSITIVE.include?(name)))
  end

  if body_size > 0
    headers = headers.push(Hpack.Header(name: "content-length".bytes, value: body_size.to_s.bytes))
  end

  size = 0
  for field in headers
    size = size + field.name.size + field.value.size + 32
    return argument("request headers exceed their limit") if size > BLOCK_LIMIT
  end

  block = try Hpack.encode(headers)
  return argument("compressed request headers exceed their limit") if block.size > BLOCK_LIMIT
  ok(block)
end

private

SENSITIVE = Set.new(["authorization", "proxy-authorization", "cookie", "set-cookie"])
CONNECTION_FIELDS = Set.new(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"])
TOKEN_MARKS = Set.new([33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126])

def token?(bytes: Bytes) -> Bool
  return false if bytes.empty?
  for byte in bytes
    digit = byte >= 48 and byte <= 57
    lowercase = byte >= 97 and byte <= 122
    return false if not digit and not lowercase and not TOKEN_MARKS.include?(byte)
  end

  true
end

def field_value?(bytes: Bytes) -> Bool
  for byte in bytes
    return false if byte == 0 or byte == 10 or byte == 13
  end

  true
end

def decimal(value: String) -> Result[Int]
  return Frame.invalid("empty decimal field") if value.empty?
  for byte in value.bytes
    return Frame.invalid("invalid decimal field") if byte < 48 or byte > 57
  end

  case value.to_i
    ok(number) -> ok(number)
    error(_) -> Frame.invalid("decimal field exceeds its limit")
  end
end

def argument[T](message: String) -> Result[T] = error("http_client: #{message}", kind: "http_client.argument")

## The Thrift compact protocol, as far as the footer of a Parquet file uses it: a struct is a map from its field id to the
## value of the field, and a list or a nested struct is a value of the same kind.

struct Read[T]
  value: T
  next: Int
end

enum Value
  Number(Int)
  Blob(Bytes)
  Flag(Bool)
  Items(List[Value])
  Fields(Map[Int, Value])
end

## The fields of the struct at `pos`, and the position after its stop byte.
def read_struct(data: Bytes, pos: Int) -> Result[Read[Map[Int, Value]]] = read_fields(data, pos, 0)

## An unsigned varint at `pos` (up to nine bytes, 63 bits, so it cannot overflow Int), and the position after it.
def varint(data: Bytes, pos: Int) -> Result[Read[Int]]
  value = 0
  at = pos
  for i in 0...MAX_VARINT_BYTES
    return malformed("a varint at #{pos} past the data") if at >= data.size

    byte = data[at]
    value = value + byte.bit_and(0x7F).shift_left(7 * i)
    at = at + 1
    return ok(Read(value: value, next: at)) if byte < 0x80
  end

  malformed("a varint at #{pos} longer than nine bytes")
end

private

MAX_DEPTH = 64
MAX_VARINT_BYTES = 9
TYPE_BOOL_TRUE = 1
TYPE_BOOL_FALSE = 2
TYPE_BYTE = 3
TYPE_DOUBLE = 7
TYPE_BINARY = 8
TYPE_LIST = 9
TYPE_SET = 10
TYPE_MAP = 11
TYPE_STRUCT = 12

def malformed[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.malformed")

def unsupported[T](message: String) -> Result[T] = error("parquet: #{message}", kind: "parquet.unsupported")

def read_fields(data: Bytes, pos: Int, depth: Int) -> Result[Read[Map[Int, Value]]]
  return malformed("structs nested deeper than #{MAX_DEPTH}") if depth >= MAX_DEPTH

  fields: Map[Int, Value] = {}
  at = pos
  last = 0
  while at < data.size
    head = data[at]
    at = at + 1
    return ok(Read(value: fields, next: at)) if head == 0

    id = last + head.shift_right(4)
    if head.shift_right(4) == 0
      number = try varint(data, at)
      id = unzigzag(number.value)
      at = number.next
    end

    kind = head.bit_and(15)
    if kind == TYPE_BOOL_TRUE or kind == TYPE_BOOL_FALSE
      fields = fields.put(id, Value.Flag(kind == TYPE_BOOL_TRUE))
    else
      field = try read_value(data, at, kind, depth)
      fields = fields.put(id, field.value)
      at = field.next
    end

    last = id
  end

  malformed("a struct with no stop byte")
end

def read_value(data: Bytes, pos: Int, kind: Int, depth: Int) -> Result[Read[Value]]
  if kind == TYPE_BYTE
    byte = try take(data, pos, 1)
    ok(Read(value: Value.Number(byte.value[0]), next: byte.next))
  elsif kind == 4 or kind == 5 or kind == 6
    integer(data, pos)
  elsif kind == TYPE_DOUBLE
    blob = try take(data, pos, 8)
    ok(Read(value: Value.Blob(blob.value), next: blob.next))
  elsif kind == TYPE_BINARY
    length = try varint(data, pos)
    blob = try take(data, length.next, length.value)
    ok(Read(value: Value.Blob(blob.value), next: blob.next))
  elsif kind == TYPE_LIST or kind == TYPE_SET
    items(data, pos, depth + 1)
  elsif kind == TYPE_STRUCT
    nested = try read_fields(data, pos, depth + 1)
    ok(Read(value: Value.Fields(nested.value), next: nested.next))
  elsif kind == TYPE_MAP
    unsupported("map fields are not read")
  else
    malformed("field type #{kind}")
  end
end

def items(data: Bytes, pos: Int, depth: Int) -> Result[Read[Value]]
  return malformed("lists nested deeper than #{MAX_DEPTH}") if depth >= MAX_DEPTH

  head = try take(data, pos, 1)
  count = head.value[0].shift_right(4)
  kind = head.value[0].bit_and(15)
  at = head.next
  if count == 15
    size = try varint(data, at)
    count = size.value
    at = size.next
  end

  return malformed("a list of #{count} items in #{data.size} bytes") if count > data.size - at

  values: List[Value] = []
  for _ in 0...count
    element = try read_element(data, at, kind, depth)
    values = values.push(element.value)
    at = element.next
  end

  ok(Read(value: Value.Items(values), next: at))
end

def read_element(data: Bytes, pos: Int, kind: Int, depth: Int) -> Result[Read[Value]]
  if kind == TYPE_BOOL_TRUE or kind == TYPE_BOOL_FALSE
    byte = try take(data, pos, 1)
    ok(Read(value: Value.Flag(byte.value[0] == TYPE_BOOL_TRUE), next: byte.next))
  else
    read_value(data, pos, kind, depth)
  end
end

def integer(data: Bytes, pos: Int) -> Result[Read[Value]]
  number = try varint(data, pos)
  ok(Read(value: Value.Number(unzigzag(number.value)), next: number.next))
end

def take(data: Bytes, pos: Int, length: Int) -> Result[Read[Bytes]]
  return malformed("#{length} bytes at #{pos} past #{data.size}") if length < 0 or length > data.size - pos

  ok(Read(value: data.slice(pos, length), next: pos + length))
end

# The zigzag code: even codes are the non-negative numbers, odd codes the negative ones.
def unzigzag(code: Int) -> Int
  return code.shift_right(1) if code.bit_and(1) == 0

  0 - code.shift_right(1) - 1
end

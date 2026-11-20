import Table from "src/table"
import Types from "src/types"
import Wire from "src/wire"

export Types.Header

struct DecoderState
  private

  table: Table.Dynamic
  allowed_capacity: Int = 4096
  pending_minimum: Optional[Int] = none
end

struct DecodedBlock
  headers: List[Types.Header]
  state: DecoderState
end

def decoder() -> DecoderState = DecoderState(table: Table.Dynamic())

def set_decoder_limit(state: DecoderState, max_table_size: Int) -> Result[DecoderState]
  if max_table_size < 0 or max_table_size > 4_294_967_295
    return error("invalid decoder table limit #{max_table_size}", kind: "hpack.limit")
  end

  pending = state.pending_minimum
  if max_table_size < state.table.capacity and max_table_size < pending.unwrap_or(state.table.capacity)
    pending = some(max_table_size)
  end

  ok(DecoderState(table: state.table, allowed_capacity: max_table_size, pending_minimum: pending))
end

def decode(state: DecoderState, block: Bytes, max_header_list_size: Int = 65536) -> Result[DecodedBlock]
  return error("invalid header list limit #{max_header_list_size}", kind: "hpack.limit") if max_header_list_size < 0

  start = try read_updates(state, block)
  table = start.table
  offset = start.next_offset
  budget = max_header_list_size
  headers: List[Types.Header] = []
  while offset < block.size
    field = try read_field(table, block, offset, budget)
    offset = field.next_offset
    budget = budget - Table.entry_size(field.header)
    headers = headers.push(field.header)
    if field.incremental
      table = Table.insert(table, field.header)
    end
  end

  next_state = DecoderState(table: table, allowed_capacity: state.allowed_capacity)
  ok(DecodedBlock(headers: headers, state: next_state))
end

def encode(headers: List[Types.Header]) -> Result[Bytes]
  table_update = Wire.write_int(0, 5, 32)
  block = Bytes.build do |out|
    out.write(table_update)
    for header in headers
      out.write(encode_field(header))
    end
  end

  ok(block)
end

private

struct BlockStart
  table: Table.Dynamic
  next_offset: Int
end

struct Field
  header: Types.Header
  next_offset: Int
  incremental: Bool = false
end

def read_updates(state: DecoderState, block: Bytes) -> Result[BlockStart]
  table = state.table
  pending = state.pending_minimum
  offset = 0
  while offset < block.size and size_update?(block[offset])
    update = try Wire.read_int(block, offset, 5)
    limit = pending.unwrap_or(state.allowed_capacity)
    if update.value > limit
      return error("table size #{update.value} exceeds #{limit} at byte #{offset}", kind: "hpack.table_size")
    end

    table = Table.resize(table, update.value)
    offset = update.next_offset
    pending = none
  end

  return error("missing table size update at byte 0", kind: "hpack.table_size") if pending.some?

  ok(BlockStart(table: table, next_offset: offset))
end

def read_field(table: Table.Dynamic, block: Bytes, offset: Int, budget: Int) -> Result[Field]
  byte = block[offset]
  return error("late table size update at byte #{offset}", kind: "hpack.table_size") if size_update?(byte)

  if byte >= 128
    index = try Wire.read_int(block, offset, 7)
    header = try Table.get(table, index.value, offset)
    return too_large(offset) if Table.entry_size(header) > budget
    return ok(Field(header: header, next_offset: index.next_offset))
  end

  return too_large(offset) if budget < 32
  incremental = byte >= 64
  prefix = 4
  if incremental
    prefix = 6
  end

  index = try Wire.read_int(block, offset, prefix)
  name = try read_name(table, block, index, offset, budget - 32)
  value = try Wire.read_string(block, name.next_offset, budget - 32 - name.data.size)
  header = Types.Header(name: name.data, value: value.data, never_indexed: byte >= 16 and byte < 32)
  ok(Field(header: header, next_offset: value.next_offset, incremental: incremental))
end

def read_name(table: Table.Dynamic, block: Bytes, index: Wire.Number, offset: Int, budget: Int) -> Result[Wire.Literal]
  return Wire.read_string(block, index.next_offset, budget) if index.value == 0

  entry = try Table.get(table, index.value, offset)
  return too_large(offset) if entry.name.size > budget
  ok(Wire.Literal(data: entry.name, next_offset: index.next_offset))
end

def encode_field(header: Types.Header) -> Bytes
  matched = Table.match_static(header)
  return Wire.write_int(matched.field_index, 7, 128) if matched.field_index > 0

  flags = 0
  if header.never_indexed
    flags = 16
  end

  Bytes.build do |out|
    out.write(Wire.write_int(matched.name_index, 4, flags))
    if matched.name_index == 0
      out.write(Wire.write_int(header.name.size, 7, 0), header.name)
    end

    out.write(Wire.write_int(header.value.size, 7, 0), header.value)
  end
end

def size_update?(byte: Int) -> Bool = byte >= 32 and byte < 64

def too_large[T](offset: Int) -> Result[T]
  error("header list exceeds its limit at byte #{offset}", kind: "hpack.header_list_size")
end

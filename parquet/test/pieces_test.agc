import Plain from "../src/plain"
import Rle from "../src/rle"
import Thrift from "../src/thrift"
import Values from "../src/values"

private

MALFORMED = "parquet.malformed"

def bytes_of(values: List[Int]) -> Bytes = Bytes.from_list(values).unwrap!

def must(condition: Bool, text: String) -> Result[Void]
  return ok() if condition

  error(text)
end

def refused[T](result: Result[T], kind: String) -> Result[Void]
  case result
    ok(_) -> error("a bad input was read")
    error(e) -> must(e.kind == kind, "gave kind #{e.kind}")
  end
end

def int_fields(data: List[Int]) -> Result[Map[Int, Thrift.Value]]
  read = try Thrift.read_struct(bytes_of(data), 0)
  ok(read.value)
end

def number_of(fields: Map[Int, Thrift.Value], id: Int) -> Int
  case fields.get(id)
    some(Thrift.Value.Number(n)) -> n
    _ -> -1000
  end
end

def test_a_varint_reads_its_bytes_and_stops_at_the_last_one() -> Result[Void]
  read = try Thrift.varint(bytes_of([0xAC, 0x02, 0x7F]), 0)
  must(read.value == 300 and read.next == 2, "read #{read.value} to #{read.next}")
end

def test_a_varint_cut_short_or_too_long_is_malformed() -> Result[Void]
  try refused(Thrift.varint(bytes_of([0x80, 0x80]), 0), MALFORMED)
  refused(Thrift.varint(bytes_of([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]), 0), MALFORMED)
end

def test_a_struct_reads_its_zigzag_integers() -> Result[Void]
  fields = try int_fields([0x15, 0x0A, 0x15, 0x05, 0x00])
  must(number_of(fields, 1) == 5 and number_of(fields, 2) == -3, "fields #{fields.size}")
end

def test_a_struct_without_its_stop_byte_is_malformed() -> Result[Void]
  refused(Thrift.read_struct(bytes_of([0x15, 0x0A]), 0), MALFORMED)
end

def test_a_list_that_claims_more_items_than_the_bytes_hold_is_malformed() -> Result[Void]
  refused(Thrift.read_struct(bytes_of([0x19, 0xF5, 0xFF, 0xFF, 0xFF, 0x0F, 0x00]), 0), MALFORMED)
end

def test_a_run_and_a_packed_group_read_back() -> Result[Void]
  run = try Rle.decode(bytes_of([8, 5]), 3, 4)
  packed = try Rle.decode(bytes_of([3, 136, 198, 250]), 3, 8)
  must(run == [5, 5, 5, 5] and packed == [0, 1, 2, 3, 4, 5, 6, 7], "run #{run} packed #{packed}")
end

def test_a_run_longer_than_the_wanted_count_is_cut() -> Result[Void]
  run = try Rle.decode(bytes_of([0xFE, 0xFF, 0xFF, 0x7F, 1]), 1, 3)
  must(run == [1, 1, 1], "run #{run}")
end

def test_a_hybrid_stream_past_its_bytes_is_malformed() -> Result[Void]
  try refused(Rle.decode(bytes_of([3, 136]), 3, 8), MALFORMED)
  try refused(Rle.decode(bytes_of([8]), 3, 4), MALFORMED)
  refused(Rle.decode(bytes_of([8, 5]), 40, 4), MALFORMED)
end

def test_plain_integers_are_little_endian_and_a_count_past_the_bytes_is_malformed() -> Result[Void]
  kind = Plain.Kind(physical: Plain.INT32, text: false, width: 0, unsigned: false)
  data = bytes_of([1, 0, 0, 0, 255, 255, 255, 255])
  decoded = try Plain.decode(kind, data, 2)
  try must(decoded == Values.Values.Integers([some(1), some(-1)]), "decoded another value")
  refused(Plain.decode(kind, data, 3), MALFORMED)
end

def test_a_byte_array_longer_than_the_data_is_malformed() -> Result[Void]
  kind = Plain.Kind(physical: Plain.BYTE_ARRAY, text: true, width: 0, unsigned: false)
  refused(Plain.decode(kind, bytes_of([9, 0, 0, 0, 97]), 1), MALFORMED)
end

def test_a_byte_array_with_no_room_for_its_length_is_malformed() -> Result[Void]
  kind = Plain.Kind(physical: Plain.BYTE_ARRAY, text: false, width: 0, unsigned: false)
  refused(Plain.decode(kind, bytes_of([1, 0, 0, 0, 97]), 2), MALFORMED)
end

def test_an_unsigned_integer_column_reads_negatives_as_large_numbers() -> Result[Void]
  kind = Plain.Kind(physical: Plain.INT32, text: false, width: 0, unsigned: true)
  decoded = try Plain.decode(kind, bytes_of([255, 255, 255, 255]), 1)
  must(decoded == Values.Values.Integers([some(4294967295)]), "decoded another value")
end

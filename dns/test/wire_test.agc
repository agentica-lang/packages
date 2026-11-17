import Binary from "std/binary"
import Name from "../src/name"
import Types from "../src/types"
import Wire from "../src/wire"

private

# A header with one question, and the answer for example.com: an A record, then a CNAME whose data points back at the
# name of the question.
HEADER = "abcd81800001000200000000"
ANSWER = (
  HEADER +
  "076578616d706c6503636f6d0000010001" +
  "c00c000100010000012c00047f000001" +
  "c00c000500010000003c0002c00c"
)
# A header with no question and one answer, and the answer from its root name on: type, class, TTL.
ONE_ANSWER = "abcd81800000000100000000" + "00"

def bytes_of(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def malformed?(message: String) -> Bool = not Wire.decode(bytes_of(message)).ok?

def test_a_query_is_the_bytes_of_the_rfc() -> Result[Void]
  query = try Wire.encode_query(4242, "example.com", Types.TYPE_A)
  Test.eq(hex(query), "109201000001000000000000076578616d706c6503636f6d0000010001")
end

def test_an_answer_with_compressed_names_is_read() -> Result[Void]
  message = try Wire.decode(bytes_of(ANSWER))
  try Test.eq(message.id, 0xabcd)
  try Test.assert(message.response and message.recursion_available, "QR and RA are set")
  try Test.eq(message.questions[0].name, "example.com")
  try Test.eq(message.answers[0].name, "example.com")
  try Test.eq(message.answers[0].ttl, 300)
  try Test.eq(message.answers[0].data, Types.Data.A("127.0.0.1"))
  Test.eq(message.answers[1].data, Types.Data.Cname("example.com"))
end

def test_an_address_is_written_as_the_rfc_5952_text() -> Result[Void]
  header = ONE_ANSWER + "001c00010000000000" + "10"
  grouped = try Wire.decode(bytes_of(header + "20010db8000000000000000000000001"))
  try Test.eq(grouped.answers[0].data, Types.Data.Aaaa("2001:db8::1"))
  # The first of two runs of the same length is the one that `::` takes, and a single zero group stays.
  runs = try Wire.decode(bytes_of(header + "00010000000100000000000100000001"))
  try Test.eq(runs.answers[0].data, Types.Data.Aaaa("1:0:1::1:0:1"))
  loopback = try Wire.decode(bytes_of(header + "00000000000000000000000000000001"))
  Test.eq(loopback.answers[0].data, Types.Data.Aaaa("::1"))
end

def test_a_pointer_that_does_not_go_back_is_refused() -> Result[Void]
  # The name of the question is a pointer to itself, then a pointer forward.
  try Test.assert(malformed?(HEADER + "c00c00010001"), "a pointer to itself")
  try Test.assert(malformed?(HEADER + "c01000010001"), "a pointer forward")
  Test.assert(malformed?(HEADER + "40" + "00010001"), "a reserved label type")
end

def test_counts_and_lengths_that_the_bytes_cannot_hold_are_refused() -> Result[Void]
  try Test.assert(malformed?("abcd0100"), "less than a header")
  try Test.assert(malformed?("abcd01000000ffff00000000"), "a count over the bytes")
  # The length of the data of the answer says 4 and 3 bytes follow.
  short = ONE_ANSWER + "00010001" + "00000000" + "0004" + "010203"
  Test.assert(malformed?(short), "data past the end")
end

def test_the_top_bit_of_a_ttl_counts_as_zero() -> Result[Void]
  message = try Wire.decode(bytes_of(ONE_ANSWER + "00010001" + "80000001" + "0004" + "01020304"))
  Test.eq(message.answers[0].ttl, 0)
end

def test_the_labels_of_a_name_are_limited() -> Result[Void]
  label = "a" * 63
  try Test.assert(Name.encode(label + "." + label + "." + label + "." + "b" * 61).ok?, "255 bytes")
  try Test.assert(not Name.encode(label + "." + label + "." + label + "." + "b" * 62).ok?, "256 bytes")
  try Test.assert(not Name.encode("a" * 64).ok?, "a label of 64 bytes")
  try Test.assert(not Name.encode("a..b").ok?, "an empty label")
  try Test.assert(not Name.encode("a\\").ok?, "a backslash at the end")
  try Test.assert(not Name.encode("a\\256").ok?, "a number over 255")
  Test.assert(not Name.encode("a\\12").ok?, "a number of two digits")
end

def test_a_name_with_escapes_reads_back_as_it_was_written() -> Result[Void]
  text = "a\\.b.c\\\\d.\\032e\\255"
  written = try Name.encode(text)
  read = try Name.decode(written, 0)
  try Test.eq(read.name, text)
  Test.eq(read.next, written.size)
end

def test_names_are_compared_as_names() -> Result[Void]
  try Test.assert(Name.same?("Example.COM", "example.com"), "A to Z")
  try Test.assert(Name.same?("example.com.", "example.com"), "a final dot")
  try Test.assert(Name.same?("\\065", "a"), "an escaped letter")
  try Test.assert(Name.same?("", "."), "the root")
  try Test.assert(not Name.same?("example.com", "example.org"), "different names")
  try Test.assert(not Name.same?("a..b", "a..b"), "a text that does not encode")
  Test.assert(not Name.same?("a\\.b", "a.b"), "a dot inside a label")
end

def test_data_of_the_wrong_size_is_refused() -> Result[Void]
  a = ONE_ANSWER + "00010001" + "00000000"
  try Test.assert(not malformed?(a + "0004" + "01020304"), "an A of 4 bytes")
  try Test.assert(malformed?(a + "0003" + "010203"), "an A of 3 bytes")
  try Test.assert(malformed?(a + "0005" + "0102030405"), "an A of 5 bytes")
  aaaa = ONE_ANSWER + "001c0001" + "00000000"
  try Test.assert(not malformed?(aaaa + "0010" + "00000000000000000000000000000001"), "an AAAA of 16 bytes")
  try Test.assert(malformed?(aaaa + "000f" + "000000000000000000000000000001"), "an AAAA of 15 bytes")
  Test.assert(malformed?(aaaa + "0011" + "0000000000000000000000000000000102"), "an AAAA of 17 bytes")
end

def test_a_name_in_the_data_of_a_record_must_fill_it() -> Result[Void]
  cname = ONE_ANSWER + "00050001" + "00000000"
  try Test.assert(not malformed?(cname + "0001" + "00"), "a name that fills the data")
  # The name ends after one byte and the data says four.
  try Test.assert(malformed?(cname + "0004" + "00" + "010203"), "a name that ends before the data")
  # The name needs two bytes and the data says one.
  Test.assert(malformed?(cname + "0001" + "0100" + "00"), "a name that ends after the data")
end

def test_a_pointer_must_go_before_its_name() -> Result[Void]
  # A label, then a pointer to the start of the same name: it loops.
  try Test.assert(malformed?("abcd01000001000000000000" + "0161c00c" + "00010001"), "a loop")
  # The pointer of the second question points at the middle of itself.
  try Test.assert(malformed?(question_pair("0161" + "00", "0161c013")), "a pointer into its own name")
  try Test.assert(not malformed?(question_pair("0161" + "00", "0161c00c")), "a pointer to the question before")
  # Offset 0 to 11 is the header.
  try Test.assert(malformed?(question_pair("0161" + "00", "c005")), "a pointer into the header")
  # The label of 3 bytes holds a 0, and the pointer goes to it: read from there the name ends, so only the rule that a
  # pointer goes before its name refuses it.
  Test.assert(malformed?("abcd01000001000000000000" + "03006162c00d" + "00010001"), "a pointer into its own label")
end

def test_a_name_follows_32_pointers_and_not_33() -> Result[Void]
  try Test.assert(not malformed?(chain(33)), "32 pointers")
  Test.assert(malformed?(chain(34)), "33 pointers")
end

def test_an_ipv4_mapped_address_ends_with_the_dotted_address() -> Result[Void]
  aaaa = ONE_ANSWER + "001c0001" + "00000000" + "0010"
  mapped = try Wire.decode(bytes_of(aaaa + "00000000000000000000ffff01020304"))
  try Test.eq(mapped.answers[0].data, Types.Data.Aaaa("::ffff:1.2.3.4"))
  other = try Wire.decode(bytes_of(aaaa + "0000000000000000000100000102ffff"))
  Test.eq(other.answers[0].data, Types.Data.Aaaa("::1:0:102:ffff"))
end

def test_the_flags_of_an_opt_record_are_kept() -> Result[Void]
  opt = try Wire.decode(bytes_of(ONE_ANSWER + "00290200" + "80000000" + "0000"))
  Test.eq(opt.answers[0].ttl, 2_147_483_648)
end

def test_many_records_that_point_at_one_long_name_are_cheap() -> Result[Void]
  name = "026162" * 30 + "00"
  count = 3000
  record = "c00c" + "00010001" + "00000000" + "0004" + "01020304"
  rows: List[Bytes] = []
  for _ in 0...count
    rows = rows.push(bytes_of(record))
  end

  header = "abcd8180" + hex(try Binary.write_u16_be(1)) + hex(try Binary.write_u16_be(count)) + "00000000"
  data = Bytes.concat([bytes_of(header + name + "00010001")] + rows)
  before = System.Profile.steps()
  message = try Wire.decode(data)
  try Test.eq(message.answers.length, count)
  try Test.eq(message.answers[count - 1].name, message.questions[0].name)
  Test.assert(System.Profile.steps() - before < 1000 * count, "the work grows with the records, not with their names")
end

def test_a_name_that_pointers_make_longer_than_255_bytes_is_refused() -> Result[Void]
  # Three labels of 63 bytes take 193 bytes with the end: a label of 61 bytes and a pointer to them make 255.
  long = ("3f" + "61" * 63) * 3 + "00"
  try Test.assert(not malformed?(question_pair(long, "3d" + "62" * 61 + "c00c")), "255 bytes")
  Test.assert(malformed?(question_pair(long, "3e" + "62" * 62 + "c00c")), "256 bytes")
end

def test_pointers_to_many_label_starts_cost_the_bytes_of_the_names() -> Result[Void]
  # 20 names of 120 labels, then a record for each label start of each name, 2400 in all.
  names = 20
  labels = 120
  question_bytes = labels * 2 + 1 + 4
  body = ""
  for index in 0...names
    body = body + one_letter_name(index, labels) + "00010001"
  end

  rows: List[Bytes] = []
  for index in 0...names
    for label in 0...labels
      offset = 12 + index * question_bytes + label * 2
      owner = hex(try Binary.write_u16_be(49_152 + offset))
      rows = rows.push(bytes_of(owner + "00010001" + "00000000" + "0004" + "01020304"))
    end
  end

  count = names * labels
  header = "abcd8180" + hex(try Binary.write_u16_be(names)) + hex(try Binary.write_u16_be(count)) + "00000000"
  data = Bytes.concat([bytes_of(header + body)] + rows)
  before = System.Profile.steps()
  message = try Wire.decode(data)
  try Test.eq(message.answers.length, count)
  Test.assert(System.Profile.steps() - before < 1000 * count, "the work grows with the bytes, not with their names")
end

def test_pointers_into_the_middle_of_labels_cost_the_bytes_of_the_names() -> Result[Void]
  # 40 names of 127 labels `01 02`. A pointer to a `02` reads it as a label of 2 bytes, which leads to the other
  # chain of
  # places: those are not the label starts of the first reading, and the name that they make must not be read again.
  names = 40
  question = "0102" * 127 + "00" + "00010001"
  rows: List[Bytes] = []
  for index in 0...4000
    offset = 12 + ((index / 126) % names) * 259 + (index % 126) * 2 + 1
    owner = hex(try Binary.write_u16_be(49_152 + offset))
    rows = rows.push(bytes_of(owner + "00100001" + "0000003c" + "0000"))
  end

  header = "abcd8180" + hex(try Binary.write_u16_be(names)) + hex(try Binary.write_u16_be(4000)) + "00000000"
  data = Bytes.concat([bytes_of(header + question * names)] + rows)
  before = System.Profile.steps()
  message = try Wire.decode(data)
  try Test.eq(message.answers.length, 4000)
  Test.assert(System.Profile.steps() - before < 1500 * 4000, "the work grows with the bytes, not with their names")
end

def test_a_chain_of_pointers_that_nobody_read_is_cut_before_it_is_followed() -> Result[Void]
  # A record of an unknown type holds 3000 names, each a pointer to the one before. The owner of the next record points
  # at the last of them: the 33rd pointer ends the walk, whatever the length of the chain.
  chain_size = 3000
  first = 12 + 3 + 4 + 12
  links = "c00c"
  for index in 1...chain_size
    links = links + hex(try Binary.write_u16_be(49_152 + first + 2 * (index - 1)))
  end

  last = first + 2 * (chain_size - 1)
  record = "c00c" + "00100001" + "00000000" + hex(try Binary.write_u16_be(chain_size * 2)) + links
  header = "abcd81800001000200000000" + "016100" + "00010001"
  owner = hex(try Binary.write_u16_be(49_152 + last))
  data = header + record + owner + "00010001" + "00000000" + "0004" + "01020304"
  before = System.Profile.steps()
  try Test.assert(malformed?(data), "the chain is too long")
  Test.assert(System.Profile.steps() - before < 100_000, "the walk stops at 33 pointers")
end

# A name of `labels` labels of one byte, the letter of `index`: hex.
def one_letter_name(index: Int, labels: Int) -> String
  label = "01" + hex(Bytes.from_list([97 + index]).unwrap!)
  label * labels + "00"
end

# Two questions: the first is `first` (a name as hex) and the type and class, the second is `second`.
def question_pair(first: String, second: String) -> String
  "abcd01000002000000000000" + first + "00010001" + second + "00010001"
end

# `count` questions in a row: the first is a label and the end of a name, each of the others a label and a pointer to
# the name before it, so the last one follows `count - 1` pointers.
def chain(count: Int) -> String
  text = "abcd0100" + hex(Binary.write_u16_be(count).unwrap!) + "000000000000" + "016100" + "00010001"
  previous = 12
  position = 12 + 7
  for _ in 1...count
    text = text + "0161" + hex(Binary.write_u16_be(49_152 + previous).unwrap!) + "00010001"
    previous = position
    position += 8
  end

  text
end

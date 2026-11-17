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

def test_names_are_compared_without_case() -> Result[Void]
  try Test.assert(Name.same?("Example.COM", "example.com"), "A to Z")
  Test.assert(not Name.same?("example.com", "example.org"), "different names")
end

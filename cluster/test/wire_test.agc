import Types from "../src/types"
import Wire from "../src/wire"

private

def bytes_of(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def name_of(length: Int) -> String = (1..length).map { |_| "a" }.join("")

# The kind of the error of a result, "" for an ok.
def kind_of[T](result: Result[T]) -> String
  case result
    ok(_) -> ""
    error(e) -> e.kind
  end
end

def test_the_preamble_is_agcn_then_the_major_version() -> Result[Void]
  try Test.eq(hex(Wire.preamble()), "4147434e0001")
  try Test.ok?(Wire.check_preamble(Wire.preamble()))
  try Test.eq(kind_of(Wire.check_preamble("GET / HTTP/1.1".bytes)), Types.PROTOCOL)
  Test.eq(kind_of(Wire.check_preamble(bytes_of("4147434e0002"))), Types.PROTOCOL)
end

def test_a_ping_is_a_length_a_kind_and_an_empty_map() -> Result[Void]
  Test.eq(hex(try Wire.encode(Types.Message.Ping)), "00000002" + "06" + "a0")
end

def test_a_mail_carries_the_mailbox_and_the_bytes_of_the_body() -> Result[Void]
  frame = try Wire.encode(Types.Message.Mail("jobs", "hi".bytes))
  # a2: a map of two; 67 "mailbox"; 64 "jobs"; 64 "body"; 42 "hi".
  body = "a2" + "676d61696c626f78" + "646a6f6273" + "64626f6479" + "426869"
  Test.eq(hex(frame), "00000017" + "05" + body)
end

def test_a_bye_carries_its_reason() -> Result[Void]
  frame = try Wire.encode(Types.Message.Bye("done"))
  Test.eq(hex(frame), "0000000e" + "08" + "a1" + "66726561736f6e" + "64646f6e65")
end

def test_a_frame_reads_back_as_it_was_written() -> Result[Void]
  messages = [
    Types.Message.Ping,
    Types.Message.Pong,
    Types.Message.Bye(""),
    Types.Message.Mail("m", Bytes.from_list([0, 255, 10]).unwrap!),
    Types.Message.Mail("jobs", "".bytes),
  ]

  for message in messages
    frame = try Wire.encode(message)
    try Test.eq(try Wire.read(frame, Types.MAX_FRAME_BYTES), message)
  end

  ok()
end

def test_the_length_is_checked_before_the_body_is_read() -> Result[Void]
  try Test.eq(try Wire.frame_length(bytes_of("000007d0"), 2000), 2000)
  try Test.eq(kind_of(Wire.frame_length(bytes_of("000007d0"), 1999)), Types.TOO_LARGE)
  try Test.eq(kind_of(Wire.frame_length(bytes_of("ffffffff"), 100)), Types.TOO_LARGE)
  try Test.eq(kind_of(Wire.frame_length(bytes_of("00000000"), 100)), Types.PROTOCOL)
  Test.eq(kind_of(Wire.frame_length(bytes_of("0000"), 100)), Types.PROTOCOL)
end

def test_a_frame_over_the_limit_is_not_written() -> Result[Void]
  big = Types.Message.Mail("jobs", Bytes.from_list([1, 2, 3]).unwrap!)
  try Test.eq(kind_of(Wire.encode(big, 10)), Types.TOO_LARGE)
  Test.ok?(Wire.encode(big, 100))
end

def test_a_mailbox_has_one_to_255_bytes() -> Result[Void]
  try Test.eq(kind_of(Wire.encode(Types.Message.Mail("", "x".bytes))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.encode(Types.Message.Mail(name_of(256), "x".bytes))), Types.PROTOCOL)
  try Test.ok?(Wire.encode(Types.Message.Mail(name_of(255), "x".bytes)))
  # The reader applies the same rule to a frame that another program wrote: an empty mailbox.
  empty_mailbox = "05" + "a2" + "676d61696c626f78" + "60" + "64626f6479" + "40"
  Test.eq(kind_of(Wire.decode(bytes_of(empty_mailbox))), Types.PROTOCOL)
end

def test_a_kind_from_64_to_127_is_ignored_and_any_other_unknown_kind_is_refused() -> Result[Void]
  try Test.eq(try Wire.decode(bytes_of("40a0")), Types.Message.Ignored(64))
  try Test.eq(try Wire.decode(bytes_of("7f")), Types.Message.Ignored(127))
  try Test.eq(kind_of(Wire.decode(bytes_of("00a0"))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.decode(bytes_of("3fa0"))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.decode(bytes_of("80a0"))), Types.PROTOCOL)
  Test.eq(kind_of(Wire.decode(bytes_of(""))), Types.PROTOCOL)
end

def test_a_body_that_is_not_the_cbor_of_its_kind_is_refused() -> Result[Void]
  bodies = ["0680", "06a000", "08a0", "08a166726561736f6e01", "05a1676d61696c626f7861" + "61"]

  for body in bodies
    try Test.eq(kind_of(Wire.decode(bytes_of(body))), Types.PROTOCOL)
  end

  ok()
end

def test_a_frame_with_bytes_after_it_or_cut_short_is_refused() -> Result[Void]
  frame = try Wire.encode(Types.Message.Mail("jobs", "hi".bytes))
  try Test.eq(kind_of(Wire.read(frame + "x".bytes, Types.MAX_FRAME_BYTES)), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.read(frame.take(frame.size - 1), Types.MAX_FRAME_BYTES)), Types.PROTOCOL)
  Test.eq(kind_of(Wire.read(frame.take(3), Types.MAX_FRAME_BYTES)), Types.PROTOCOL)
end

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

def test_a_key_that_the_reader_does_not_know_is_ignored() -> Result[Void]
  try Test.eq(try Wire.decode(bytes_of("06a1617801")), Types.Message.Ping)
  # A field that is added later, in a mail: a key "x" with a text.
  mail = "05" + "a3" + "676d61696c626f78" + "646a6f6273" + "64626f6479" + "40" + "6178" + "6161"
  Test.eq(try Wire.decode(bytes_of(mail)), Types.Message.Mail("jobs", "".bytes))
end

def test_hostile_cbor_is_a_protocol_error_and_never_halts() -> Result[Void]
  nested = (1..20_000).map { |_| "81" }.join("") + "00"
  mailbox = "676d61696c626f78" + "646a6f6273"
  hostile = [
    # cut inside the body
    "05a2",
    "08a1",
    "08a166726561736f6e",
    # a length far over the bytes that follow, as text and as bytes
    "08a166726561736f6e7bffffffffffffffff",
    "08a166726561736f6e7affffffff",
    "05a2" + mailbox + "64626f64795affffffff",
    "08a166726561736f6e5b7fffffffffffffff",
    # indefinite lengths
    "06bfff",
    "089f",
    "08a166726561736f6e7f6161ff",
    # nesting past the limit, in a key that the reader ignores
    "05a3" + mailbox + "64626f6479" + "40" + "6178" + nested,
    # a text that is not UTF-8
    "05a2" + "676d61696c626f78" + "61ff" + "64626f6479" + "40",
    # a key twice
    "08a266726561736f6e6066726561736f6e60",
    # a tag, a float, a map where a text goes
    "08a166726561736f6ec060",
    "08a166726561736f6efb3ff0000000000000",
    "08a166726561736f6ea0",
  ]

  for payload in hostile
    try Test.eq(kind_of(Wire.decode(bytes_of(payload))), Types.PROTOCOL)
  end

  ok()
end

def test_the_handshake_messages_read_back_as_they_were_written() -> Result[Void]
  nonce = Bytes.from_list((1..32).map { |n| n }).unwrap!
  proof = Bytes.from_list((1..32).map { |n| 255 - n }).unwrap!
  messages = [
    Types.Message.Hello("alpha", nonce),
    Types.Message.Challenge("beta", nonce, proof),
    Types.Message.Proof(proof),
    Types.Message.Welcome,
  ]

  for message in messages
    frame = try Wire.encode(message)
    try Test.eq(try Wire.read(frame, Types.MAX_FRAME_BYTES), message)
  end

  ok()
end

def test_a_hello_is_a_name_and_a_nonce_of_32_bytes() -> Result[Void]
  nonce = "00000000000000000000000000000000".bytes
  frame = try Wire.encode(Types.Message.Hello("alpha", nonce))
  # 01 hello; a2 a map of two; "node" "alpha"; "nonce" then a byte string of 32 bytes (5820).
  body = "a2" + "646e6f6465" + "65616c706861" + "656e6f6e6365" + "5820" + hex(nonce)
  Test.eq(hex(frame), "00000035" + "01" + body)
end

def test_a_handshake_frame_with_a_bad_name_nonce_or_proof_is_refused() -> Result[Void]
  nonce = "00000000000000000000000000000000".bytes
  short = "0000000000".bytes
  try Test.eq(kind_of(Wire.encode(Types.Message.Hello("Alpha", nonce))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.encode(Types.Message.Hello("", nonce))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.encode(Types.Message.Hello("alpha", short))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.encode(Types.Message.Challenge("beta", nonce, short))), Types.PROTOCOL)
  try Test.eq(kind_of(Wire.encode(Types.Message.Proof(short))), Types.PROTOCOL)
  # The reader applies the same rules: a hello with an upper case name, and a proof of 5 bytes.
  bad_name = "01" + "a2" + "646e6f6465" + "6141" + "656e6f6e6365" + "5820" + hex(nonce)
  bad_proof = "03" + "a1" + "6570726f6f66" + "450000000000"
  try Test.eq(kind_of(Wire.decode(bytes_of(bad_name))), Types.PROTOCOL)
  Test.eq(kind_of(Wire.decode(bytes_of(bad_proof))), Types.PROTOCOL)
end

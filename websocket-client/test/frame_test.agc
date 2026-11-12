import Frame from "../src/frame"

KEY = Bytes.from_list([0x37, 0xfa, 0x21, 0x3d]).unwrap!

def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def bytes_of(text: String) -> Bytes = OpenSSL.Digest.hexdecode(text).unwrap!

def head(frame: String) -> Frame.Head
  data = bytes_of(frame)
  first = Frame.head_of(data.take(2))
  Frame.complete(first, data.slice(2, Frame.tail_size(first)))
end

def problem_code(found: Optional[Frame.Problem]) -> Int
  case found
    some(problem) -> problem.code
    none -> 0
  end
end

def start(frame: Bytes, size: Int) -> String = hex(frame).slice(0, size)

def filler(size: Int) -> Bytes = ("a" * size).bytes

# RFC 6455 5.7: a single-frame masked text message "Hello".
def test_a_masked_hello_is_the_frame_of_the_rfc() -> Result[Void]
  Test.eq(hex(Frame.encode(Frame.TEXT, "Hello".bytes, KEY)), "818537fa213d7f9f4d5158")
end

def test_the_length_takes_the_shortest_form() -> Result[Void]
  try Test.eq(start(Frame.encode(Frame.BINARY, filler(125), KEY), 4), "82fd")
  try Test.eq(start(Frame.encode(Frame.BINARY, filler(126), KEY), 8), "82fe007e")
  try Test.eq(start(Frame.encode(Frame.BINARY, filler(65535), KEY), 8), "82feffff")
  try Test.eq(start(Frame.encode(Frame.BINARY, filler(65536), KEY), 28), "82ff00000000000100" + "0037fa213d")
  Test.eq(Frame.encode(Frame.BINARY, filler(65536), KEY).size, 10 + 4 + 65536)
end

# What a server does with a frame of this client: read the head, the tail, the payload, and unmask it.
def test_a_frame_reads_back_as_it_was_written() -> Result[Void]
  sizes = [0, 1, 5, 124, 125, 126, 127, 300, 4000]
  opcodes = [Frame.TEXT, Frame.BINARY, Frame.PING, Frame.PONG]
  for round in 0..35
    opcode = opcodes[round % 4]
    size = sizes[round % 9]
    if opcode == Frame.PING or opcode == Frame.PONG
      size = size % 126
    end

    sent = OpenSSL.Random.random_bytes(size)
    key = OpenSSL.Random.random_bytes(4)
    wire = Frame.encode(opcode, sent, key)
    first = Frame.head_of(wire.take(2))
    full = Frame.complete(first, wire.slice(2, Frame.tail_size(first)))
    body = wire.drop(2 + Frame.tail_size(first))
    try Test.eq(full.opcode, opcode)
    try Test.assert(full.fin and full.masked, "a client frame is whole and masked")
    try Test.eq(full.length, size)
    try Test.eq(full.key, key)
    try Test.eq(Frame.mask(body, full.key), sent)
  end

  ok()
end

def test_masking_twice_gives_the_data_back() -> Result[Void]
  data = "masking is its own inverse".bytes
  Test.eq(Frame.mask(Frame.mask(data, KEY), KEY), data)
end

def test_a_server_frame_head_is_read() -> Result[Void]
  frame = head("8105")
  try Test.assert(frame.fin and not frame.masked, "FIN set and not masked")
  try Test.eq(frame.opcode, Frame.TEXT)
  try Test.eq(frame.length, 5)
  try Test.eq(Frame.tail_size(Frame.head_of(bytes_of("817e"))), 2)
  try Test.eq(Frame.tail_size(Frame.head_of(bytes_of("817f"))), 8)
  try Test.eq(head("827e0100").length, 256)
  Test.eq(head("827f0000000000010000").length, 65536)
end

def test_a_frame_that_a_server_must_not_send_is_refused() -> Result[Void]
  max = 1000
  try Test.eq(problem_code(Frame.check_head(head("8105"), max, 0)), 0)
  try Test.eq(problem_code(Frame.check_head(head("8185" + "37fa213d"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("c105"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("a105"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("8305"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("0900"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("897e007e"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("897d"), max, 0)), 0)
  Test.eq(problem_code(Frame.check_head(head("827fffffffffffffffff"), max, 0)), Frame.CLOSE_PROTOCOL)
end

def test_a_message_over_the_limit_is_refused_by_its_head() -> Result[Void]
  try Test.eq(problem_code(Frame.check_head(head("82" + "7d"), 125, 0)), 0)
  try Test.eq(problem_code(Frame.check_head(head("82" + "7e007e"), 125, 0)), Frame.CLOSE_TOO_BIG)
  # The fragments before count too.
  try Test.eq(problem_code(Frame.check_head(head("0004"), 10, 7)), Frame.CLOSE_TOO_BIG)
  # A control frame inside a fragmented message does not.
  Test.eq(problem_code(Frame.check_head(head("8904"), 10, 9)), 0)
end

# A frame of a few bytes as hex: its first byte (FIN and the opcode) and its payload.
def frame_of(first: String, payload: Bytes) -> String
  first + hex(Bytes.from_list([payload.size]).unwrap!) + hex(payload)
end

def take_frame(assembly: Frame.Assembly, first: String, payload: Bytes, max: Int) -> Frame.Taken
  Frame.take(assembly, head(frame_of(first, payload)), payload, max)
end

def more_of(taken: Frame.Taken) -> Frame.Assembly
  case taken
    Frame.Taken.More(assembly) -> assembly
    Frame.Taken.Whole(_, _) -> Frame.new_assembly()
    Frame.Taken.Broken(_) -> Frame.new_assembly()
  end
end

def broken_code(taken: Frame.Taken) -> Int
  case taken
    Frame.Taken.Broken(problem) -> problem.code
    Frame.Taken.More(_) -> 0
    Frame.Taken.Whole(_, _) -> 0
  end
end

def test_fragments_join_into_one_message() -> Result[Void]
  first = more_of(take_frame(Frame.new_assembly(), "01", "Hi".bytes, 100))
  second = more_of(take_frame(first, "00", " th".bytes, 100))
  Test.eq(take_frame(second, "80", "ere".bytes, 100), Frame.Taken.Whole(true, "Hi there".bytes))
end

def test_a_binary_message_is_not_checked_for_utf8() -> Result[Void]
  Test.eq(take_frame(Frame.new_assembly(), "82", bytes_of("c328"), 100), Frame.Taken.Whole(false, bytes_of("c328")))
end

def test_a_character_may_be_split_between_fragments() -> Result[Void]
  first = more_of(take_frame(Frame.new_assembly(), "01", bytes_of("c3"), 100))
  Test.eq(take_frame(first, "80", bytes_of("a9"), 100), Frame.Taken.Whole(true, bytes_of("c3a9")))
end

def test_a_text_that_is_not_utf8_is_bad_data() -> Result[Void]
  Test.eq(broken_code(take_frame(Frame.new_assembly(), "81", bytes_of("c328"), 100)), Frame.CLOSE_BAD_DATA)
end

def test_fragments_that_break_the_order_are_refused() -> Result[Void]
  try Test.eq(broken_code(take_frame(Frame.new_assembly(), "80", "x".bytes, 100)), Frame.CLOSE_PROTOCOL)
  open = more_of(take_frame(Frame.new_assembly(), "01", "x".bytes, 100))
  Test.eq(broken_code(take_frame(open, "81", "y".bytes, 100)), Frame.CLOSE_PROTOCOL)
end

def test_fragments_count_together_against_the_limit() -> Result[Void]
  first = more_of(take_frame(Frame.new_assembly(), "01", "12345".bytes, 8))
  Test.eq(broken_code(take_frame(first, "80", "6789".bytes, 8)), Frame.CLOSE_TOO_BIG)
end

def test_a_close_frame_has_a_code_and_a_reason() -> Result[Void]
  try Test.eq(Frame.parse_close(bytes_of("")), Frame.Closing.Peer(1005, ""))
  try Test.eq(Frame.parse_close(bytes_of("03e8")), Frame.Closing.Peer(1000, ""))
  try Test.eq(Frame.parse_close(bytes_of("03e9") + "bye".bytes), Frame.Closing.Peer(1001, "bye"))
  try Test.eq(
    Frame.parse_close(bytes_of("03")),
    Frame.Closing.Invalid(Frame.Problem(code: 1002, reason: "a close frame of one byte")),
  )

  case Frame.parse_close(bytes_of("03ed"))
    Frame.Closing.Invalid(problem) -> try Test.eq(problem.code, Frame.CLOSE_PROTOCOL)
    Frame.Closing.Peer(_, _) -> try Test.assert(false, "1005 on the wire is invalid")
  end

  case Frame.parse_close(bytes_of("03e8c328"))
    Frame.Closing.Invalid(problem) -> Test.eq(problem.code, Frame.CLOSE_BAD_DATA)
    Frame.Closing.Peer(_, _) -> Test.assert(false, "a reason that is not UTF-8 is invalid")
  end
end

def test_a_close_payload_is_checked_before_it_is_sent() -> Result[Void]
  try Test.eq(Frame.close_payload(1000, "done"), ok(bytes_of("03e8") + "done".bytes))
  try Test.eq(Frame.close_payload(3000, ""), ok(bytes_of("0bb8")))
  try Test.error?(Frame.close_payload(1005, ""))
  try Test.error?(Frame.close_payload(999, ""))
  try Test.error?(Frame.close_payload(1000, "x" * 124))
  Test.ok?(Frame.close_payload(1000, "x" * 123))
end

# 1 + (2^63 - 1) would overflow an Int if the held bytes were added to a length from the network.
def test_a_huge_length_after_a_fragment_does_not_overflow() -> Result[Void]
  Test.eq(problem_code(Frame.check_head(head("807f7fffffffffffffff"), 10, 1)), Frame.CLOSE_TOO_BIG)
end

def test_a_length_must_have_its_shortest_form() -> Result[Void]
  max = 100_000
  try Test.eq(problem_code(Frame.check_head(head("827e0005"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("827e007d"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("827e007e"), max, 0)), 0)
  try Test.eq(problem_code(Frame.check_head(head("827f000000000000ffff"), max, 0)), Frame.CLOSE_PROTOCOL)
  try Test.eq(problem_code(Frame.check_head(head("827f0000000000010000"), max, 0)), 0)
  # A control frame with a long form is refused anyway.
  Test.eq(problem_code(Frame.check_head(head("897e0005"), max, 0)), Frame.CLOSE_PROTOCOL)
end

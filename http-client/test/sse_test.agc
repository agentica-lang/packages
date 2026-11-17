import Sse from "../src/sse"
import {Event} from "../src/sse"

private

STREAM = (
  ":hi\r\nevent: add\r\ndata: 1\r\ndata:2\r\nid: 7\r\n\r\ndata: é\rdata\r\r: x\nevent: none\n\nretry: 5\ndata: last\n\n"
)
LINES = 4_000
LINE_BYTES = 1_000
# Several times what the long event takes when each line costs what it holds.
LINEAR_MS = 1_000
WANTED = [
  Event(event: "add", data: "1\n2", id: "7"),
  Event(event: "message", data: "é\n", id: "7"),
  Event(event: "message", data: "last", id: "7"),
]

def fed(pieces: List[Bytes], max_bytes: Int) -> Result[List[Event]]
  parser = Sse.parser()
  events: List[Event] = []
  for piece in pieces
    done = try Sse.feed(parser, piece, max_bytes)
    parser = done.parser
    events = events + done.events
  end

  ok(events)
end

def test_the_events_are_the_same_wherever_the_pieces_split() -> Result[Void]
  bytes = Bytes.from_list([0xEF, 0xBB, 0xBF]).unwrap! + STREAM.bytes
  try Test.eq(try fed([bytes], 1_000), WANTED)
  for at in 0..bytes.size
    try Test.eq(try fed([bytes.take(at), bytes.drop(at)], 1_000), WANTED)
  end

  Test.eq(try fed(bytes.to_a.map { |byte| Bytes.from_list([byte]).unwrap! }, 1_000), WANTED)
end

def test_an_event_over_the_limit_is_too_large() -> Result[Void]
  case fed(["data: #{"a" * 50}\n".bytes, "data: more\n".bytes], 40)
    ok(_) -> error("an event over the limit was read")
    error(e) -> Test.eq(e.kind, "http_client.too_large")
  end
end

# Each line costs what it holds, however long the event: a parser that copies the data of the event so far on each
# line copies gigabytes for these 4 MB, and takes seconds.
def test_a_long_event_costs_what_it_holds() -> Result[Void]
  line = "data: #{"x" * LINE_BYTES}\n"
  stream = (line * LINES + "\n").bytes
  began = Time.monotonic_ms()
  read = try Sse.feed(Sse.parser(), stream, stream.size)
  elapsed = Time.monotonic_ms() - began
  try Test.eq(read.events.size, 1)
  try Test.eq(read.events[0].data.length, LINES * (LINE_BYTES + 1) - 1)
  Test.eq(elapsed < LINEAR_MS, true)
end

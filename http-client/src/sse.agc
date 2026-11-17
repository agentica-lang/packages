## The reading of server-sent events (the `text/event-stream` of the HTML standard, section 9.2.6), one piece of the
## body at a time: lines end with CRLF, LF or CR, a blank line ends an event, a line that starts with `:` is a comment,
## and the fields are `event`, `data` and `id` (`retry` and other fields are skipped).

import Exchange from "exchange"

## An event: its type (`message` when it names none), its data (the `data` lines joined by newlines) and the last
## event ID the stream gave.
struct Event
  event: String
  data: String
  id: String
end

## What is read so far: the bytes after the last line end, and the event that the lines so far build.
struct Parser
  pending: Bytes
  after_cr: Bool
  started: Bool
  event: String
  data: String
  has_data: Bool
  id: String
end

## The parser after `piece`, and the events it ends.
struct Fed
  parser: Parser
  events: List[Event]
end

## A parser at the start of a stream.
def parser() -> Parser
  Parser(pending: NO_BYTES, after_cr: false, started: false, event: "", data: "", has_data: false, id: "")
end

## Reads `piece`. An event, or a line, of more than `max_bytes` is an `http_client.too_large` error, and text that is
## not UTF-8 an `http_client.decode` error.
def feed(parser: Parser, piece: Bytes, max_bytes: Int) -> Result[Fed]
  at = piece.size - 1
  while at >= 0 and piece[at] != LF and piece[at] != CR
    at = at - 1
  end

  if at < 0
    pending = parser.pending + piece
    return too_large() if pending.size + parser.data.bytesize > max_bytes

    return ok(Fed(parser: parser.with(pending: pending), events: []))
  end

  complete = parser.pending + piece.take(at + 1)
  if not parser.started and complete.take(3) == bom()
    complete = complete.drop(3)
  end

  text = try decoded(complete)
  rest = piece.drop(at + 1)

  if parser.after_cr and text.start_with?("\n")
    text = text.slice(1, text.length - 1)
  end

  state = parser.with(pending: rest, after_cr: text.end_with?("\r"), started: true)
  events: List[Event] = []
  lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
  for line in lines.take(lines.size - 1)
    if line.empty?
      if state.has_data
        events = events.push(Event(event: name_of(state.event), data: state.data, id: state.id))
      end

      state = state.with(event: "", data: "", has_data: false)
    else
      state = read_line(state, line)
    end

    return too_large() if state.data.bytesize + rest.size > max_bytes
  end

  ok(Fed(parser: state, events: events))
end

private

NO_BYTES = "".bytes
LF = "\n".code
CR = "\r".code

def read_line(state: Parser, line: String) -> Parser
  return state if line.start_with?(":")

  field = line
  value = ""
  case line.index_of(":")
    some(colon) ->
      field = line.slice(0, colon)
      value = line.slice(colon + 1, line.length - colon - 1)
      if value.start_with?(" ")
        value = value.slice(1, value.length - 1)
      end

    none -> nil
  end

  case field
    "event" -> state.with(event: value)
    "data" if state.has_data -> state.with(data: "#{state.data}\n#{value}")
    "data" -> state.with(data: value, has_data: true)
    "id" if not value.bytes.to_a.include?(0) -> state.with(id: value)
    _ -> state
  end
end

def bom() -> Bytes = Bytes.from_list([0xEF, 0xBB, 0xBF]).unwrap!

def name_of(event: String) -> String
  return "message" if event.empty?

  event
end

def decoded(bytes: Bytes) -> Result[String]
  case String.from_bytes(bytes)
    ok(text) -> ok(text)
    error(e) -> Exchange.failure("the events are not UTF-8", "decode", some(e))
  end
end

def too_large[T]() -> Result[T] = Exchange.failure("an event is over its limit", "too_large")

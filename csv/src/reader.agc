## Reading: the whole text at once, or chunks of it. A byte order mark (U+FEFF) at the start of the text is dropped.

import Scan from "scan"

export Scan.Reader
export Scan.Feed

def new(separator: String) -> Result[Scan.Reader]
  byte = try Scan.separator_byte(separator)
  ok(Scan.start(byte))
end

## The rows that the chunk finishes. A row may stop in the middle of a chunk and go on in the next.
def feed(reader: Scan.Reader, chunk: String) -> Result[Scan.Feed]
  return Scan.feed(reader, chunk, false) if reader.started

  return ok(Scan.Feed(reader: reader, rows: [])) if chunk.empty?

  Scan.feed(reader, unmarked(chunk), false)
end

## The last row, which may have no line break, once the text is over.
def finish(reader: Scan.Reader) -> Result[List[List[String]]]
  done = try Scan.feed(reader, "", true)
  ok(done.rows)
end

## Every row of the text.
def parse(text: String, separator: String) -> Result[List[List[String]]]
  byte = try Scan.separator_byte(separator)
  done = try Scan.feed(Scan.start(byte), unmarked(text), true)
  ok(done.rows)
end

private

def unmarked(text: String) -> String
  return text.slice(1, text.length - 1) if text.start_with?(String.from_code(65279))

  text
end

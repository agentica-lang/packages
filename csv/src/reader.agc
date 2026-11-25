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
  bytes = chunk.bytes
  return Scan.feed(reader, bytes, false) if reader.started

  return ok(Scan.Feed(reader: reader, rows: [])) if bytes.size == 0

  Scan.feed(reader, unmarked(bytes), false)
end

## The last row, which may have no line break, once the text is over.
def finish(reader: Scan.Reader) -> Result[List[List[String]]]
  done = try Scan.feed(reader, "".bytes, true)
  ok(done.rows)
end

## Every row of the text.
def parse(text: String, separator: String) -> Result[List[List[String]]]
  byte = try Scan.separator_byte(separator)
  done = try Scan.feed(Scan.start(byte), unmarked(text.bytes), true)
  ok(done.rows)
end

private

# U+FEFF in UTF-8.
BOM = [239, 187, 191]

def unmarked(bytes: Bytes) -> Bytes
  if bytes.size >= 3 and bytes[0] == BOM[0] and bytes[1] == BOM[1] and bytes[2] == BOM[2]
    return bytes.slice(3, bytes.size - 3)
  end

  bytes
end

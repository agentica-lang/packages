## Reading: the whole text at once, or chunks of it through a reader that keeps the bytes of the row it has not finished.

import Errors from "errors"
import Scan from "scan"

## A reader between chunks: its separator, the bytes of the unfinished row, and the line that row starts on.
struct Reader
  separator: Int
  rest: Bytes
  line: Int
end

## What a chunk gave: the reader to feed next and the rows the chunk finished.
struct Feed
  reader: Reader
  rows: List[List[String]]
end

def new(separator: String) -> Result[Reader]
  byte = try Scan.separator_byte(separator)
  ok(Reader(separator: byte, rest: "".bytes, line: 1))
end

## The rows that the chunk finishes. A row may stop in the middle of a chunk and go on in the next.
def feed(reader: Reader, chunk: String) -> Result[Feed]
  data = reader.rest + chunk.bytes
  rows: List[List[String]] = []
  at = 0
  line = reader.line
  going = true
  while going and at < data.size
    step = try Scan.row(data, at, reader.separator, line, false)
    case step
      Scan.Step.Row(scanned) ->
        rows = rows.push(scanned.fields)
        at = scanned.next
        line = line + scanned.breaks
      Scan.Step.More -> going = false
    end
  end

  rest = data.slice(at, data.size - at)
  ok(Feed(reader: Reader(separator: reader.separator, rest: rest, line: line), rows: rows))
end

## The last row, which may have no line break, once the text is over.
def finish(reader: Reader) -> Result[List[List[String]]]
  all(reader.rest, reader.separator, reader.line)
end

## Every row of the text.
def parse(text: String, separator: String) -> Result[List[List[String]]]
  byte = try Scan.separator_byte(separator)
  all(text.bytes, byte, 1)
end

private

def all(data: Bytes, separator: Int, first: Int) -> Result[List[List[String]]]
  rows: List[List[String]] = []
  at = 0
  line = first
  while at < data.size
    step = try Scan.row(data, at, separator, line, true)
    case step
      Scan.Step.Row(scanned) ->
        rows = rows.push(scanned.fields)
        at = scanned.next
        line = line + scanned.breaks
      Scan.Step.More -> return Errors.malformed("the text ends inside a row at line #{line}")
    end
  end

  ok(rows)
end

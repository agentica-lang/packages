## The state machine of the reader. It goes over the bytes of a chunk once and keeps what it knows between chunks: the
## fields of the row in progress, how the field in progress stands, and the bytes of it that are not decided yet. Quote,
## separator, CR and LF are ASCII, so a field is cut on byte positions and every piece is valid UTF-8 when the text is.

import Errors from "errors"

## The reader between two chunks.
struct Reader
  separator: Int
  fields: List[String]
  mode: Int
  pieces: List[Bytes]
  # One byte (a quote or a CR) at the end of the last chunk whose meaning depends on the next one.
  edge: Bytes
  line: Int
  breaks: Int
  started: Bool
end

## What a chunk gave: the reader to use for the next chunk and the rows the chunk finished.
struct Feed
  reader: Reader
  rows: List[List[String]]
end

## The separator as its byte: one printable ASCII character that is not a quote.
def separator_byte(separator: String) -> Result[Int]
  bytes = separator.bytes
  return Errors.invalid("the separator must be one character of one byte, not #{bytes.size} bytes") if bytes.size != 1

  byte = bytes[0]
  return Errors.invalid("the separator cannot be a quote") if byte == QUOTE
  return Errors.invalid("the separator cannot be a line break") if byte == LF or byte == CR
  return Errors.invalid("the separator must be printable ASCII or a tab") if byte != TAB and (byte < 32 or byte > 126)

  ok(byte)
end

## A reader at the start of a text.
def start(separator: Int) -> Reader
  Reader(separator: separator, fields: [], mode: START, pieces: [], edge: "".bytes, line: 1, breaks: 0, started: false)
end

## Reads the chunk after what the reader holds. `eof` says the chunk is the end of the text, so the last row may have no
## line break and an open quote is an error.
def feed(reader: Reader, chunk: Bytes, eof: Bool) -> Result[Feed]
  data = reader.edge + chunk
  separator = reader.separator
  fields = reader.fields
  mode = reader.mode
  pieces = reader.pieces
  line = reader.line
  breaks = reader.breaks
  rows: List[List[String]] = []
  edge = "".bytes
  i = 0
  seg = 0
  while i < data.size
    byte = data[i]
    if mode == START
      if byte == QUOTE
        mode = QUOTED
        i = i + 1
      else
        mode = BARE
      end

      seg = i
    elsif mode == BARE
      if byte == QUOTE
        return Errors.malformed("a quote inside a field that does not start with one at line #{line}")
      elsif byte == separator or byte == LF
        fields = fields.push(joined(pieces.push(data.slice(seg, i - seg)), byte == LF))
        pieces = []
        mode = START
        if byte == LF
          rows = rows.push(fields)
          fields = []
          line = line + 1
        end

        i = i + 1
        seg = i
      else
        i = i + 1
      end
    elsif mode == QUOTED
      if byte == QUOTE and i + 1 >= data.size and !eof
        pieces = pieces.push(data.slice(seg, i - seg))
        edge = data.slice(i, 1)
        i = data.size
        seg = i
      elsif byte == QUOTE and i + 1 < data.size and data[i + 1] == QUOTE
        pieces = pieces.push(data.slice(seg, i + 1 - seg))
        i = i + 2
        seg = i
      elsif byte == QUOTE
        pieces = pieces.push(data.slice(seg, i - seg))
        mode = AFTER
        i = i + 1
        seg = i
      else
        if byte == LF
          breaks = breaks + 1
        end

        i = i + 1
      end
    else
      if byte == separator or byte == LF
        fields = fields.push(joined(pieces, false))
        pieces = []
        mode = START
        line = line + breaks
        breaks = 0
        if byte == LF
          rows = rows.push(fields)
          fields = []
          line = line + 1
        end

        i = i + 1
        seg = i
      elsif byte == CR and i + 1 >= data.size and !eof
        edge = data.slice(i, 1)
        i = data.size
      elsif byte == CR and i + 1 < data.size and data[i + 1] == LF
        fields = fields.push(joined(pieces, false))
        rows = rows.push(fields)
        fields = []
        pieces = []
        mode = START
        line = line + breaks + 1
        breaks = 0
        i = i + 2
        seg = i
      else
        return Errors.malformed("text after a closing quote at line #{line + breaks}")
      end
    end
  end

  if eof
    if mode == QUOTED
      return Errors.malformed("the quote opened at line #{line} is never closed")
    elsif mode == BARE
      rows = rows.push(fields.push(joined(pieces.push(data.slice(seg, data.size - seg)), false)))
      fields = []
      pieces = []
      mode = START
    elsif mode == AFTER
      rows = rows.push(fields.push(joined(pieces, false)))
      fields = []
      pieces = []
      mode = START
    elsif !fields.empty?
      rows = rows.push(fields.push(""))
      fields = []
    end
  elsif (mode == BARE or (mode == QUOTED and edge.size == 0)) and seg < data.size
    pieces = pieces.push(data.slice(seg, data.size - seg))
  end

  ok(
    Feed(
      reader: Reader(
        separator: separator,
        fields: fields,
        mode: mode,
        pieces: pieces,
        edge: edge,
        line: line,
        breaks: breaks,
        started: true,
      ),
      rows: rows,
    ),
  )
end

private

QUOTE = 34
LF = 10
CR = 13
TAB = 9
START = 0
BARE = 1
QUOTED = 2

# A closing quote has been read: a separator, a line break or the end of the text must follow.
AFTER = 3

# The field from its pieces. A CR before the LF that ends a field with no quotes belongs to the line break. The pieces
# are cut at ASCII bytes of a valid String, so they are valid UTF-8.
def joined(pieces: List[Bytes], strip_cr: Bool) -> String
  bytes = pieces[0]
  if pieces.size != 1
    bytes = Bytes.concat(pieces)
  end

  if strip_cr and bytes.size > 0 and bytes[bytes.size - 1] == CR
    bytes = bytes.slice(0, bytes.size - 1)
  end

  String.from_bytes(bytes).unwrap!
end

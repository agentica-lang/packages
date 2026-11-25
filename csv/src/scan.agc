## The reader: a text is cut into lines with the native `split`, and a complete line with no quote, read between two
## rows, is cut into fields with `split` too. Every other line goes through the state machine (`run`), which keeps what
## it knows between chunks. Quote, separator, CR and LF are ASCII, so a field is cut on byte positions and every piece
## is valid UTF-8 when the text is.

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
def feed(reader: Reader, chunk: String, eof: Bool) -> Result[Feed]
  separator = String.from_code(reader.separator)
  lines = chunk.split("\n")
  last = lines.size - 1
  marks = chunk.include?(QUOTE_TEXT)
  returns = chunk.include?("\r")
  state = reader
  line = reader.line
  rows: List[List[String]] = []
  index = 0
  while index < last
    if clean?(state)
      while index < last
        plain = lines[index]
        break if marks and plain.include?(QUOTE_TEXT)

        if returns and plain.end_with?("\r")
          plain = plain.slice(0, plain.length - 1)
        end

        rows = rows.push(plain.split(separator))
        line = line + 1
        index = index + 1
      end
    end

    if index < last
      parts: List[String] = []
      inside = open_count(state)
      while index < last
        parts = parts.push(lines[index])
        if marks
          inside = inside + lines[index].split(QUOTE_TEXT).size - 1
        end

        index = index + 1
        break if inside % 2 == 0 and (index >= last or !marks or !lines[index].include?(QUOTE_TEXT))
      end

      reaches_end = index >= last
      if reaches_end
        parts = parts.push(lines[last])
        index = last + 1
      end

      text = parts.join("\n")
      if !reaches_end
        text = text + "\n"
      end

      done = try run(at_line(state, line), text.bytes, reaches_end and eof)
      rows = appended(rows, done.rows)
      state = done.reader
      line = state.line
    end
  end

  if index == last
    done = try run(at_line(state, line), lines[last].bytes, eof)
    return ok(Feed(reader: done.reader, rows: appended(rows, done.rows)))
  end

  ok(Feed(reader: state, rows: rows))
end

## One pass of the state machine over the chunk, whatever its lines.
def run(reader: Reader, chunk: Bytes, eof: Bool) -> Result[Feed]
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
QUOTE_TEXT = "\""
LF = 10
CR = 13
TAB = 9
START = 0
BARE = 1
QUOTED = 2

# A closing quote has been read: a separator, a line break or the end of the text must follow.
AFTER = 3

def appended(rows: List[List[String]], more: List[List[String]]) -> List[List[String]]
  return more if rows.empty?

  out = rows
  for row in more
    out = out.push(row)
  end

  out
end

# Between two rows, with nothing of a row read.
def clean?(reader: Reader) -> Bool = reader.mode == START and reader.fields.empty? and reader.pieces.empty?

# The quotes the reader has opened and not closed, counted as the parity of the quotes it has read.
def open_count(reader: Reader) -> Int
  count = 0
  if reader.mode == QUOTED
    count = 1
  end

  if reader.edge.size > 0 and reader.edge[0] == QUOTE
    count = count + 1
  end

  count
end

def at_line(reader: Reader, line: Int) -> Reader
  Reader(
    separator: reader.separator,
    fields: reader.fields,
    mode: reader.mode,
    pieces: reader.pieces,
    edge: reader.edge,
    line: line,
    breaks: reader.breaks,
    started: reader.started,
  )
end

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

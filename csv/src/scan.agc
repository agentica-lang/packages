## The state machine of the reader: one row at a time from a position of the bytes. Quote, comma-like separator, CR and LF
## are ASCII, so the fields are cut on byte positions and every piece is valid UTF-8 when the whole text is.

import Errors from "errors"

## The fields of one row, the position after its terminator, and how many line breaks it held (inside quotes too).
struct Scanned
  fields: List[String]
  next: Int
  breaks: Int
end

## A row, or `More` when the bytes end before the row does (only when the end of the text is not known yet).
enum Step
  Row(Scanned)
  More
end

## The separator as its byte: one printable ASCII character that is not a quote.
def separator_byte(separator: String) -> Result[Int]
  bytes = separator.bytes
  return Errors.invalid("the separator must be one character, not #{separator.size}") if bytes.size != 1

  byte = bytes[0]
  return Errors.invalid("the separator cannot be a quote") if byte == QUOTE
  return Errors.invalid("the separator cannot be a line break") if byte == LF or byte == CR
  return Errors.invalid("the separator must be printable ASCII or a tab") if byte != TAB and (byte < 32 or byte > 126)

  ok(byte)
end

## The row that starts at `at`. `eof` says the bytes are the whole text, so the last row may end without a line break.
def row(data: Bytes, at: Int, separator: Int, line: Int, eof: Bool) -> Result[Step]
  fields_from(data, at, separator, line, eof, [], 0)
end

private

QUOTE = 34
LF = 10
CR = 13
TAB = 9

# A field and what ended it: a separator (`row_ends` false) or the end of the row.
struct Field
  text: String
  next: Int
  row_ends: Bool
  breaks: Int
end

def fields_from(
  data: Bytes,
  pos: Int,
  separator: Int,
  line: Int,
  eof: Bool,
  fields: List[String],
  breaks: Int,
) -> Result[Step]
  found = try one_field(data, pos, separator, line + breaks, eof)
  case found
    none -> ok(Step.More)
    some(field) ->
      all = fields.push(field.text)
      seen = breaks + field.breaks
      if field.row_ends
        ok(Step.Row(Scanned(fields: all, next: field.next, breaks: seen)))
      else
        fields_from(data, field.next, separator, line, eof, all, seen)
      end
  end
end

def one_field(data: Bytes, pos: Int, separator: Int, line: Int, eof: Bool) -> Result[Optional[Field]]
  if pos < data.size and data[pos] == QUOTE
    quoted(data, pos, separator, line, eof)
  else
    bare(data, pos, separator, line, eof)
  end
end

def text_of(bytes: Bytes, line: Int) -> Result[String]
  case String.from_bytes(bytes)
    ok(text) -> ok(text)
    error(_) -> Errors.malformed("text that is not UTF-8 at line #{line}")
  end
end

def made(bytes: Bytes, line: Int, next: Int, row_ends: Bool, breaks: Int) -> Result[Optional[Field]]
  text = try text_of(bytes, line)
  ok(some(Field(text: text, next: next, row_ends: row_ends, breaks: breaks)))
end

# A field with no quotes: up to a separator or a line break. A CR before the LF belongs to the terminator.
def bare(data: Bytes, pos: Int, separator: Int, line: Int, eof: Bool) -> Result[Optional[Field]]
  i = pos
  while i < data.size and data[i] != separator and data[i] != LF
    return Errors.malformed("a quote inside a field that does not start with one at line #{line}") if data[i] == QUOTE

    i = i + 1
  end

  if i >= data.size
    return ok(none) if !eof

    return made(data.slice(pos, i - pos), line, i, true, 0)
  end

  return made(data.slice(pos, i - pos), line, i + 1, false, 0) if data[i] == separator

  stop = i
  if stop > pos and data[stop - 1] == CR
    stop = stop - 1
  end

  made(data.slice(pos, stop - pos), line, i + 1, true, 1)
end

# A quoted field: `""` is a quote, and a lone quote closes it. What follows must be a separator, a line break or
# the end.
def quoted(data: Bytes, pos: Int, separator: Int, line: Int, eof: Bool) -> Result[Optional[Field]]
  pieces: List[Bytes] = []
  segment = pos + 1
  i = pos + 1
  breaks = 0
  while i < data.size
    byte = data[i]
    if byte == QUOTE
      if i + 1 >= data.size
        return ok(none) if !eof

        return closed(data, pieces, segment, i, i + 1, separator, line, eof, breaks)
      elsif data[i + 1] == QUOTE
        pieces = pieces.push(data.slice(segment, i + 1 - segment))
        i = i + 2
        segment = i
      else
        return closed(data, pieces, segment, i, i + 1, separator, line, eof, breaks)
      end
    else
      if byte == LF
        breaks = breaks + 1
      end

      i = i + 1
    end
  end

  return ok(none) if !eof

  Errors.malformed("the quote opened at line #{line} is never closed")
end

# The quote at `quote` closes the field, which ends with `after`: the byte that follows it, if there is one.
def closed(
  data: Bytes,
  pieces: List[Bytes],
  segment: Int,
  quote: Int,
  after: Int,
  separator: Int,
  line: Int,
  eof: Bool,
  breaks: Int,
) -> Result[Optional[Field]]
  bytes = Bytes.concat(pieces.push(data.slice(segment, quote - segment)))
  at = line + breaks
  return made(bytes, line, after, true, breaks) if after >= data.size and eof
  return ok(none) if after >= data.size
  return made(bytes, line, after + 1, false, breaks) if data[after] == separator
  return made(bytes, line, after + 1, true, breaks + 1) if data[after] == LF

  if data[after] == CR
    return ok(none) if after + 1 >= data.size and !eof
    return made(bytes, line, after + 2, true, breaks + 1) if after + 1 < data.size and data[after + 1] == LF
  end

  Errors.malformed("text after a closing quote at line #{at}")
end

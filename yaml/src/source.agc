## The text under parse as bytes, the tests on one byte that the scanner and the parser share, and the errors, which
## name the line and the column of a byte offset. Every byte that YAML gives a meaning is ASCII, so the parser walks
## the UTF-8 bytes and never splits a character.

import Types from "types"

EOF = 0
TAB = 9
BREAK = 10
SPACE = 32
BANG = 33
QUOTE = 34
HASH = 35
PERCENT = 37
AMPERSAND = 38
APOSTROPHE = 39
STAR = 42
COMMA = 44
DASH = 45
DOT = 46
COLON = 58
LESS = 60
GREATER = 62
QUESTION = 63
AT = 64
OPEN_BRACKET = 91
BACKSLASH = 92
CLOSE_BRACKET = 93
BACKTICK = 96
OPEN_BRACE = 123
PIPE = 124
CLOSE_BRACE = 125
## A plain scalar never starts with one of these, except `-`, `?` and `:` before a character that is not blank.
INDICATORS = Set.new([
  DASH,
  QUESTION,
  COLON,
  COMMA,
  OPEN_BRACKET,
  CLOSE_BRACKET,
  OPEN_BRACE,
  CLOSE_BRACE,
  HASH,
  AMPERSAND,
  STAR,
  BANG,
  PIPE,
  GREATER,
  APOSTROPHE,
  QUOTE,
  PERCENT,
  AT,
  BACKTICK,
])
FLOW_INDICATORS = Set.new([COMMA, OPEN_BRACKET, CLOSE_BRACKET, OPEN_BRACE, CLOSE_BRACE])
## The tag handles of a document with no `%TAG` directive.
DEFAULT_HANDLES = {"!": "!", "!!": "tag:yaml.org,2002:"}

## The text of a parse: its bytes with line breaks made `\n` and a NUL after the end, so a look ahead never leaves the
## bytes; `size` is where the text ends. `handles` are the tag handles of the document being parsed.
struct Source
  bytes: Bytes
  size: Int
  options: Types.Options
  handles: Map[String, String]
end

def from_text(text: String, options: Types.Options) -> Source
  data = text.replace("\r\n", "\n").replace("\r", "\n").bytes
  if data.size >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF
    data = data.drop(3)
  end

  Source(bytes: data + PADDING, size: data.size, options: options, handles: DEFAULT_HANDLES)
end

def blank?(c: Int) -> Bool = c == SPACE or c == TAB

def blank_or_end?(c: Int) -> Bool = c == SPACE or c == TAB or c == BREAK or c == EOF

def flow_indicator?(c: Int) -> Bool = FLOW_INDICATORS.include?(c)

def indicator?(c: Int) -> Bool = INDICATORS.include?(c)

## The text of the bytes from `start` to `stop`.
def text(src: Source, start: Int, stop: Int) -> String
  String.from_bytes(src.bytes.slice(start, stop - start)).unwrap!
end

def skip_blanks(src: Source, pos: Int) -> Int
  bytes = src.bytes
  i = pos
  c = bytes[i]
  while c == SPACE or c == TAB
    i += 1
    c = bytes[i]
  end

  i
end

def skip_spaces(src: Source, pos: Int) -> Int
  bytes = src.bytes
  i = pos
  while bytes[i] == SPACE
    i += 1
  end

  i
end

def skip_to_break(src: Source, pos: Int) -> Int
  i = pos
  while src.bytes[i] != BREAK and i < src.size
    i += 1
  end

  i
end

## From the start of a line, the start of the next line that holds more than blanks and a comment (or the end).
def skip_empty_lines(src: Source, pos: Int) -> Int
  start = pos
  while start < src.size
    i = skip_blanks(src, start)
    if src.bytes[i] == HASH
      i = skip_to_break(src, i)
    end

    return src.size if i >= src.size
    return start if src.bytes[i] != BREAK

    start = i + 1
  end

  src.size
end

## The offset of the first byte `c` of the text, or its end.
def find_byte(src: Source, c: Int) -> Int
  i = 0
  while i < src.size and src.bytes[i] != c
    i += 1
  end

  i
end

## Whether `pos` starts a line with `---` or `...` and a blank or the end after it.
def document_marker?(src: Source, pos: Int) -> Bool
  return false if pos >= src.size or (pos > 0 and src.bytes[pos - 1] != BREAK)

  c = src.bytes[pos]
  return false if c != DASH and c != DOT

  src.bytes[pos + 1] == c and src.bytes[pos + 2] == c and blank_or_end?(src.bytes[pos + 3])
end

def start_marker?(src: Source, pos: Int) -> Bool = document_marker?(src, pos) and src.bytes[pos] == DASH

def end_marker?(src: Source, pos: Int) -> Bool = document_marker?(src, pos) and src.bytes[pos] == DOT

## A failed parse at `pos`. The error keeps the offset; `located` turns it into a line and a column, once, at the API,
## so a failure that the parser expects (a line that is not a key) costs nothing.
def fail[T](src: Source, pos: Int, message: String) -> Result[T] = failure(pos, message, "yaml.parse")

## A limit of the options that the text passes.
def over_limit[T](src: Source, pos: Int, message: String) -> Result[T] = failure(pos, message, "yaml.limit")

## The result with the offset of its error made a line and a column (from 1, in characters).
def located[T](src: Source, result: Result[T]) -> Result[T]
  case result
    ok(value) -> ok(value)
    error(e) if e.details.key?(OFFSET) -> at_line(src, e.details[OFFSET].to_i!, e.message, e.kind)
    error(e) -> error(e)
  end
end

private

PADDING = Bytes.from_list([0, 0, 0, 0, 0]).unwrap!
OFFSET = "offset"

def failure[T](pos: Int, message: String, kind: String) -> Result[T]
  error(message, kind: kind, details: {OFFSET: "#{pos}"})
end

def at_line[T](src: Source, pos: Int, message: String, kind: String) -> Result[T]
  lines = String.from_bytes(src.bytes.take([pos, src.size].min.unwrap_or(0))).unwrap!.split("\n")
  line = lines.size
  col = lines.last.length + 1
  error("line #{line}, column #{col}: #{message}", kind: kind, details: {"line": "#{line}", "column": "#{col}"})
end

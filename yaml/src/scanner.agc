## The scanner: the scalars of every style (plain, single- and double-quoted, literal and folded), the anchors and the
## tags. Each function starts at a byte offset and gives the text it read and the offset after it.

import Source from "source"

## The text that a scan read and where the scan stopped.
struct Scanned
  text: String
  pos: Int
end

## Where a plain scalar is: in a block (it may span lines), in a block mapping key (one line) or in a flow collection
## (it stops at `,`, `[`, `]`, `{` and `}`).
enum Context
  Block
  BlockKey
  Flow
end

def plain_start?(src: Source.Source, pos: Int, flow: Bool) -> Bool
  c = src.bytes[pos]
  return false if Source.blank_or_end?(c)

  if c == Source.DASH or c == Source.QUESTION or c == Source.COLON
    next_byte = src.bytes[pos + 1]
    return not Source.blank_or_end?(next_byte) and not (flow and Source.flow_indicator?(next_byte))
  end

  not Source.indicator?(c)
end

## A plain scalar from `pos`. Its lines after the first must be indented more than `n`; one line break between two
## lines folds to a space, and each empty line is a line feed.
def plain(src: Source.Source, pos: Int, n: Int, context: Context) -> Result[Scanned]
  flow = context == Context.Flow
  return Source.fail(src, pos, "unexpected character") if not plain_start?(src, pos, flow)

  parts: List[String] = []
  i = pos
  stop = pos
  while true
    start = i
    end_of_text = i
    c = src.bytes[i]
    while c != Source.BREAK and i < src.size
      if c == Source.SPACE or c == Source.TAB
        i += 1
      else
        break if (c == Source.COLON or c == Source.HASH or flow) and plain_end?(src, i, c, flow)

        i += 1
        end_of_text = i
      end

      c = src.bytes[i]
    end

    parts = parts.push(Source.text(src, start, end_of_text))
    stop = end_of_text
    break if c != Source.BREAK or i >= src.size or context == Context.BlockKey

    next_line = continuation(src, i, n, flow)
    case next_line
      some(found) ->
        parts = parts.push(found.text)
        i = found.pos
      none -> break
    end
  end

  ok(Scanned(text: parts.join(""), pos: stop))
end

def single_quoted(src: Source.Source, pos: Int, n: Int) -> Result[Scanned]
  parts: List[String] = []
  i = pos + 1
  run = i
  while true
    return Source.fail(src, pos, "unterminated single-quoted scalar") if i >= src.size

    c = src.bytes[i]
    if c == Source.APOSTROPHE
      parts = parts.push(Source.text(src, run, i))
      return ok(Scanned(text: parts.join(""), pos: i + 1)) if src.bytes[i + 1] != Source.APOSTROPHE

      parts = parts.push("'")
      i += 2
      run = i
    elsif Source.blank?(c) or c == Source.BREAK
      blank_end = Source.skip_blanks(src, i)
      if src.bytes[blank_end] == Source.BREAK
        parts = parts.push(Source.text(src, run, i))
        folded = try fold(src, blank_end, n, false)
        parts = parts.push(folded.text)
        i = folded.pos
        run = i
      else
        i = blank_end
      end
    else
      i += 1
    end
  end

  Source.fail(src, pos, "unterminated single-quoted scalar")
end

def double_quoted(src: Source.Source, pos: Int, n: Int) -> Result[Scanned]
  parts: List[String] = []
  i = pos + 1
  run = i
  while true
    return Source.fail(src, pos, "unterminated double-quoted scalar") if i >= src.size

    c = src.bytes[i]
    if c == Source.QUOTE
      parts = parts.push(Source.text(src, run, i))
      return ok(Scanned(text: parts.join(""), pos: i + 1))
    elsif c == Source.BACKSLASH
      parts = parts.push(Source.text(src, run, i))
      if src.bytes[i + 1] == Source.BREAK
        folded = try fold(src, i + 1, n, true)
        parts = parts.push(folded.text)
        i = folded.pos
      else
        escaped = try escape(src, i)
        parts = parts.push(escaped.text)
        i = escaped.pos
      end

      run = i
    elsif Source.blank?(c) or c == Source.BREAK
      blank_end = Source.skip_blanks(src, i)
      if src.bytes[blank_end] == Source.BREAK
        parts = parts.push(Source.text(src, run, i))
        folded = try fold(src, blank_end, n, false)
        parts = parts.push(folded.text)
        i = folded.pos
        run = i
      else
        i = blank_end
      end
    else
      i += 1
    end
  end

  Source.fail(src, pos, "unterminated double-quoted scalar")
end

## A literal (`|`) or folded (`>`) scalar whose header is at `pos`, in a node indented `n`. It stops at the start of
## the first line that is not its own.
def block_scalar(src: Source.Source, pos: Int, n: Int) -> Result[Scanned]
  header = try block_header(src, pos)
  first_line = Source.skip_to_break(src, header.after) + 1
  indent = n + header.increment
  if header.increment == 0
    indent = try detect_indent(src, first_line, n)
  end

  folded = src.bytes[pos] == Source.GREATER
  parts: List[String] = []
  line = first_line
  pending = 0
  seen = false
  more_indented = false
  had_break = false
  while line < src.size and not Source.document_marker?(src, line)
    first = Source.skip_spaces(src, line)
    spaces = first - line
    c = src.bytes[first]
    if (c == Source.BREAK or first >= src.size) and spaces <= indent
      pending += 1
      line = first + 1
    elsif spaces < indent
      return Source.fail(src, first, "a tab cannot indent a block scalar") if c == Source.TAB

      break
    else
      start = line + indent
      stop = Source.skip_to_break(src, start)
      indented = Source.blank?(src.bytes[start])
      if not seen
        parts = parts.push("\n" * pending)
      elsif folded and not indented and not more_indented
        parts = parts.push(folding(pending))
      else
        parts = parts.push("\n" * (pending + 1))
      end

      parts = parts.push(Source.text(src, start, stop))
      pending = 0
      seen = true
      more_indented = indented
      # A last line of blanks counts as a whole line, as the yaml-test-suite reads it.
      had_break = stop < src.size or Source.skip_blanks(src, start) == stop
      line = stop + 1
    end
  end

  if line > src.size
    line = src.size
  end

  if seen and header.chomp != Chomp.Strip and had_break
    parts = parts.push("\n")
  end

  if header.chomp == Chomp.Keep
    parts = parts.push("\n" * pending)
  end

  ok(Scanned(text: parts.join(""), pos: line))
end

## The name of an anchor or an alias whose indicator (`&` or `*`) is at `pos`.
def anchor(src: Source.Source, pos: Int) -> Result[Scanned]
  i = pos + 1
  while not Source.blank_or_end?(src.bytes[i]) and not Source.flow_indicator?(src.bytes[i])
    i += 1
  end

  return Source.fail(src, pos, "an anchor or alias needs a name") if i == pos + 1

  ok(Scanned(text: Source.text(src, pos + 1, i), pos: i))
end

## The tag at `pos`, resolved through the handles of the document (`!!str` is `tag:yaml.org,2002:str`).
def tag(src: Source.Source, pos: Int) -> Result[Scanned]
  if src.bytes[pos + 1] == Source.LESS
    i = pos + 2
    while src.bytes[i] != Source.GREATER
      return Source.fail(src, pos, "unterminated verbatim tag") if Source.blank_or_end?(src.bytes[i])

      i += 1
    end

    return ok(Scanned(text: Source.text(src, pos + 2, i), pos: i + 1))
  end

  i = pos + 1
  handle_end = pos + 1
  while not Source.blank_or_end?(src.bytes[i]) and not Source.flow_indicator?(src.bytes[i])
    if src.bytes[i] == Source.BANG and handle_end == pos + 1
      handle_end = i + 1
    end

    i += 1
  end

  raw = Source.text(src, pos, i)
  return ok(Scanned(text: "!", pos: i)) if raw == "!"

  handle = Source.text(src, pos, handle_end)
  suffix = Source.text(src, handle_end, i)
  case src.handles.get(handle)
    some(prefix) if suffix != "" or handle == "!" -> ok(Scanned(text: prefix + suffix, pos: i))
    some(_) -> Source.fail(src, pos, "the tag #{raw} has no suffix")
    none -> Source.fail(src, pos, "undefined tag handle #{handle}")
  end
end

private

ESCAPES: Map[Int, String] = {
  "0".code: String.from_code(0),
  "a".code: String.from_code(7),
  "b".code: String.from_code(8),
  "t".code: "\t",
  Source.TAB: "\t",
  "n".code: "\n",
  "v".code: String.from_code(11),
  "f".code: String.from_code(12),
  "r".code: "\r",
  "e".code: String.from_code(27),
  Source.SPACE: " ",
  Source.QUOTE: "\"",
  "/".code: "/",
  Source.BACKSLASH: "\\",
  "N".code: String.from_code(0x85),
  "_".code: String.from_code(0xA0),
  "L".code: String.from_code(0x2028),
  "P".code: String.from_code(0x2029),
}
HEX_ESCAPES: Map[Int, Int] = {"x".code: 2, "u".code: 4, "U".code: 8}
DIGIT_ZERO = 48
DIGIT_NINE = 57
PLUS = 43
MAX_CODE = 0x10FFFF

enum Chomp
  Clip
  Strip
  Keep
end

struct Header
  chomp: Chomp
  increment: Int
  after: Int
end

def plain_end?(src: Source.Source, i: Int, c: Int, flow: Bool) -> Bool
  if c == Source.COLON
    next_byte = src.bytes[i + 1]
    return Source.blank_or_end?(next_byte) or (flow and Source.flow_indicator?(next_byte))
  end

  return Source.blank?(src.bytes[i - 1]) if c == Source.HASH

  flow and Source.flow_indicator?(c)
end

# The line breaks and the indentation before the next line of a plain scalar, folded, and where that line's text
# starts; none when the scalar ends at the break at `pos`.
def continuation(src: Source.Source, pos: Int, n: Int, flow: Bool) -> Optional[Scanned]
  line = pos + 1
  breaks = 0
  first = Source.skip_blanks(src, line)
  while src.bytes[first] == Source.BREAK and first < src.size
    breaks += 1
    line = first + 1
    first = Source.skip_blanks(src, line)
  end

  return none if first >= src.size or Source.document_marker?(src, line)
  return none if Source.skip_spaces(src, line) - line <= n

  c = src.bytes[first]
  return none if c == Source.HASH or (flow and Source.flow_indicator?(c))
  return none if plain_end?(src, first, c, flow)

  some(Scanned(text: folding(breaks), pos: first))
end

# One line break between two lines folds to a space; with empty lines between, each of those is a line feed.
def folding(breaks: Int) -> String
  if breaks == 0
    " "
  else
    "\n" * breaks
  end
end

# The line break of a quoted scalar at `pos`: the empty lines after it are line feeds; with none, the break is a space
# (nothing when a backslash escaped it). The next line must be indented more than `n`.
def fold(src: Source.Source, pos: Int, n: Int, escaped: Bool) -> Result[Scanned]
  line = pos + 1
  breaks = 0
  first = Source.skip_blanks(src, line)
  while src.bytes[first] == Source.BREAK and first < src.size
    breaks += 1
    line = first + 1
    first = Source.skip_blanks(src, line)
  end

  return Source.fail(src, first, "unterminated quoted scalar") if first >= src.size
  return Source.fail(src, line, "a document marker inside a quoted scalar") if Source.document_marker?(src, line)
  return Source.fail(src, first, "bad indentation in a quoted scalar") if Source.skip_spaces(src, line) - line <= n

  text = "\n" * breaks
  if not escaped
    text = folding(breaks)
  end

  ok(Scanned(text: text, pos: first))
end

def escape(src: Source.Source, pos: Int) -> Result[Scanned]
  c = src.bytes[pos + 1]
  case ESCAPES.get(c)
    some(text) -> return ok(Scanned(text: text, pos: pos + 2))
    none -> nil
  end

  digits = HEX_ESCAPES.get(c, 0)
  return Source.fail(src, pos, "unknown escape") if digits == 0

  code = 0
  for i in (pos + 2)...(pos + 2 + digits)
    value = hex_value(src.bytes[i])
    return Source.fail(src, pos, "bad hex digit in an escape") if value < 0

    code = code * 16 + value
  end

  if code > MAX_CODE or (code >= 0xD800 and code <= 0xDFFF)
    return Source.fail(src, pos, "the escape is not a Unicode character")
  end

  ok(Scanned(text: String.from_code(code), pos: pos + 2 + digits))
end

def hex_value(c: Int) -> Int
  if c >= DIGIT_ZERO and c <= DIGIT_NINE
    c - DIGIT_ZERO
  elsif c >= "a".code and c <= "f".code
    c - "a".code + 10
  elsif c >= "A".code and c <= "F".code
    c - "A".code + 10
  else
    -1
  end
end

def block_header(src: Source.Source, pos: Int) -> Result[Header]
  chomp = Chomp.Clip
  increment = 0
  i = pos + 1
  for _ in 0...2
    c = src.bytes[i]
    if c > DIGIT_ZERO and c <= DIGIT_NINE and increment == 0
      increment = c - DIGIT_ZERO
    elsif c == PLUS and chomp == Chomp.Clip
      chomp = Chomp.Keep
    elsif c == Source.DASH and chomp == Chomp.Clip
      chomp = Chomp.Strip
    elsif c == DIGIT_ZERO
      return Source.fail(src, i, "the indentation indicator of a block scalar is 1 to 9")
    else
      break
    end

    i += 1
  end

  after = Source.skip_blanks(src, i)
  if src.bytes[after] == Source.HASH
    return Source.fail(src, after, "a comment needs a space before it") if after == i
  elsif src.bytes[after] != Source.BREAK and after < src.size
    return Source.fail(src, after, "unexpected text after the header of a block scalar")
  end

  ok(Header(chomp: chomp, increment: increment, after: after))
end

# The indentation of the first line with text; an empty line before it may not have more spaces.
def detect_indent(src: Source.Source, pos: Int, n: Int) -> Result[Int]
  line = pos
  widest = 0
  while line < src.size
    first = Source.skip_spaces(src, line)
    spaces = first - line
    return ok([n + 1, widest, spaces].max.unwrap_or(0)) if first >= src.size

    if src.bytes[first] != Source.BREAK
      return ok([n + 1, widest].max.unwrap_or(0)) if Source.document_marker?(src, line)
      return ok(n + 1) if spaces <= n
      return Source.fail(src, line, "an empty line has more spaces than the block scalar's text") if spaces < widest

      return ok(spaces)
    end

    widest = [widest, spaces].max.unwrap_or(0)
    line = first + 1
  end

  ok([n + 1, widest].max.unwrap_or(0))
end

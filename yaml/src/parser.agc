## The parser: the documents of a stream, block and flow collections, and the properties (anchor, tag) of their nodes.
## It gives a tree of `Types.Node` per document; the composer turns that tree into JSON.
##
## A block parse function starts at the first byte of its node and returns the start of the first line after it that
## holds more than blanks and a comment, so its caller reads that line's indentation to see where the node ends.

import Scanner from "scanner"
import Source from "source"
import Types from "types"

## A node and the offset after it.
struct Parsed
  node: Types.Node
  pos: Int
end

## A document of the stream and where it starts.
struct Document
  node: Types.Node
  pos: Int
end

def stream(src: Source.Source) -> Result[List[Document]]
  documents: List[Document] = []
  pos = 0
  while true
    pos = Source.skip_empty_lines(src, pos)
    break if pos >= src.size

    directives = try directives(src, pos)
    pos = directives.pos
    if pos >= src.size
      return Source.fail(src, pos, "a directive needs a document after it") if directives.found

      break
    end

    if Source.end_marker?(src, pos) and not directives.found
      pos = try finish_line(src, pos + 3)
      next
    end

    parsed = try document(src.with(handles: directives.handles), pos, directives.found)
    documents = documents.push(Document(node: parsed.node, pos: pos))
    pos = parsed.pos
    if pos < src.size
      if Source.end_marker?(src, pos)
        pos = try finish_line(src, pos + 3)
      elsif not Source.start_marker?(src, pos)
        text = Source.skip_blanks(src, pos)
        return Source.fail(src, text, "mapping values are not allowed here") if src.bytes[text] == Source.COLON

        return Source.fail(src, text, "expected the end of the document")
      end
    end
  end

  ok(documents)
end

private

MAX_KEY_LENGTH = 1024
YAML_DIRECTIVE = "YAML"
TAG_DIRECTIVE = "TAG"

# Where a block node is: after `-`, after `?` or an explicit `:` (both may hold a compact collection on the same
# line), after the `:` of an implicit key (that and an explicit entry may hold a sequence at the parent's
# indentation), or at the top of a document.
enum Kind
  Entry
  Explicit
  Value
  Document
end

struct Props
  meta: Types.Meta
  found: Bool
  pos: Int
end

struct Pair
  key: Types.Node
  value: Types.Node
  pos: Int
end

struct Directives
  handles: Map[String, String]
  found: Bool
  pos: Int
end

def no_meta(pos: Int) -> Types.Meta = Types.Meta(anchor: "", tag: "", pos: pos)

def empty(pos: Int) -> Types.Node = Types.Node.Scalar(no_meta(pos), true, "")

# A node's position is that of its properties, or of its text when it has none.
def placed(meta: Types.Meta, pos: Int) -> Types.Meta
  return meta if meta.anchor != "" or meta.tag != ""

  meta.with(pos: pos)
end

def empty_with(meta: Types.Meta) -> Types.Node = Types.Node.Scalar(meta, true, "")

def document(src: Source.Source, pos: Int, after_directives: Bool) -> Result[Parsed]
  return block_node(src, pos + 3, -1, Kind.Document, 0) if Source.start_marker?(src, pos)
  return Source.fail(src, pos, "expected '---' after the directives") if after_directives

  node_on_next_lines(src, pos, -1, Kind.Document, 0, no_meta(pos))
end

def directives(src: Source.Source, start: Int) -> Result[Directives]
  handles = Source.DEFAULT_HANDLES
  found = false
  seen_version = false
  pos = start
  while pos < src.size and src.bytes[pos] == Source.PERCENT
    name_end = word_end(src, pos + 1)
    name = Source.text(src, pos + 1, name_end)
    first = Source.skip_blanks(src, name_end)
    second = Source.skip_blanks(src, word_end(src, first))
    after = Source.skip_blanks(src, word_end(src, second))
    if name == YAML_DIRECTIVE
      return Source.fail(src, pos, "a second %YAML directive") if seen_version

      version = Source.text(src, first, word_end(src, first)).split(".")
      if version.size != 2 or not version.all?(&number?) or version[0] != "1"
        return Source.fail(src, first, "unsupported YAML version #{version.join(".")}")
      end

      seen_version = true
      after = second
    elsif name == TAG_DIRECTIVE
      handle = Source.text(src, first, word_end(src, first))
      prefix = Source.text(src, second, word_end(src, second))
      return Source.fail(src, first, "a %TAG directive needs a handle and a prefix") if prefix == ""

      handles = handles.put(handle, prefix)
    else
      after = Source.skip_to_break(src, pos)
    end

    found = true
    pos = try finish_line(src, after)
  end

  ok(Directives(handles: handles, found: found, pos: pos))
end

def number?(text: String) -> Bool
  text != "" and text.split("").all? do |c| c.code >= "0".code and c.code <= "9".code end
end

def word_end(src: Source.Source, pos: Int) -> Int
  i = pos
  while not Source.blank_or_end?(src.bytes[i])
    i += 1
  end

  i
end

# The rest of a line after a node: blanks and a comment, then the start of the next line with text.
def finish_line(src: Source.Source, pos: Int) -> Result[Int]
  i = Source.skip_blanks(src, pos)
  c = src.bytes[i]
  if c == Source.HASH
    if i == pos and pos > 0 and not Source.blank_or_end?(src.bytes[pos - 1])
      return Source.fail(src, i, "a comment needs a space before it")
    end

    i = Source.skip_to_break(src, i)
  elsif c == Source.COLON and i < src.size
    return Source.fail(src, i, "mapping values are not allowed here")
  elsif c != Source.BREAK and i < src.size
    return Source.fail(src, i, "unexpected text after a node")
  end

  return ok(src.size) if i >= src.size

  ok(Source.skip_empty_lines(src, i + 1))
end

# A block node after an indicator at `pos` (or a document start), in a parent indented `n`.
def block_node(src: Source.Source, pos: Int, n: Int, kind: Kind, depth: Int) -> Result[Parsed]
  p = Source.skip_blanks(src, pos)
  c = src.bytes[p]
  if (kind == Kind.Entry or kind == Kind.Explicit) and p < src.size
    if Source.text(src, pos, p).include?("\t") and block_collection?(src, p, depth)
      return Source.fail(src, p, "a tab cannot indent a block collection")
    end

    # The indicator before `pos` is at column `n`.
    indent = n + 1 + p - pos
    marker = Source.blank_or_end?(src.bytes[p + 1])
    return block_seq(src, p, indent, depth + 1, no_meta(p)) if c == Source.DASH and marker
    return block_map(src, p, indent, depth + 1, no_meta(p)) if map_indicator?(c) and marker
    return block_map(src, p, indent, depth + 1, no_meta(p)) if key_on_line?(src, p, depth)
  end

  node_with_props(src, p, n, kind, depth, no_meta(p))
end

# The properties at `pos` (if any), then their node: on the same line, or on the lines after.
def node_with_props(src: Source.Source, pos: Int, n: Int, kind: Kind, depth: Int, outer: Types.Meta) -> Result[Parsed]
  props = try props(src, pos)
  if outer.anchor != "" and props.meta.anchor != ""
    return Source.fail(src, pos, "a node has one anchor")
  elsif outer.tag != "" and props.meta.tag != ""
    return Source.fail(src, pos, "a node has one tag")
  end

  meta = props.meta
  if outer.anchor != ""
    meta = meta.with(anchor: outer.anchor)
  end

  if outer.tag != ""
    meta = meta.with(tag: outer.tag)
  end

  q = props.pos
  c = src.bytes[q]
  if c == Source.HASH or c == Source.BREAK or q >= src.size
    next_line = try finish_line(src, q)
    return node_on_next_lines(src, next_line, n, kind, depth, meta)
  end

  if props.found and not Source.blank?(src.bytes[props.pos - 1])
    return Source.fail(src, q, "properties need a space after them")
  end

  line_node(src, q, n, depth, meta)
end

# A node that starts at the first line with text after its indicator's line (`next_line` is that line's start).
def node_on_next_lines(
  src: Source.Source,
  next_line: Int,
  n: Int,
  kind: Kind,
  depth: Int,
  meta: Types.Meta,
) -> Result[Parsed]
  return ok(Parsed(node: empty_with(meta), pos: next_line)) if next_line >= src.size

  return ok(Parsed(node: empty_with(meta), pos: next_line)) if Source.document_marker?(src, next_line)

  first = Source.skip_spaces(src, next_line)
  indent = first - next_line
  c = src.bytes[first]
  if c == Source.TAB
    return ok(Parsed(node: empty_with(meta), pos: next_line)) if indent <= n

    content = Source.skip_blanks(src, first)
    return Source.fail(src, first, "a tab cannot indent a block collection") if block_collection?(src, content, depth)

    return node_with_props(src, content, n, kind, depth, meta)
  end

  marker = Source.blank_or_end?(src.bytes[first + 1])
  if indent > n
    return block_seq(src, first, indent, depth + 1, meta) if c == Source.DASH and marker
    return block_map(src, first, indent, depth + 1, meta) if map_indicator?(c) and marker
    return block_map(src, first, indent, depth + 1, meta) if key_on_line?(src, first, depth)

    return node_with_props(src, first, n, kind, depth, meta)
  end

  if indent == n and (kind == Kind.Value or kind == Kind.Explicit) and c == Source.DASH and marker
    return block_seq(src, first, indent, depth + 1, meta)
  end

  ok(Parsed(node: empty_with(meta), pos: next_line))
end

def block_collection?(src: Source.Source, pos: Int, depth: Int) -> Bool
  c = src.bytes[pos]
  marker = Source.blank_or_end?(src.bytes[pos + 1])
  ((c == Source.DASH or map_indicator?(c)) and marker) or key_on_line?(src, pos, depth)
end

# `?` starts an explicit key, and `:` an entry with an empty key.
def map_indicator?(c: Int) -> Bool = c == Source.QUESTION or c == Source.COLON

# A node that is not a block collection, at `pos`: a block scalar, an alias, or a flow node and the rest of its line.
def line_node(src: Source.Source, pos: Int, n: Int, depth: Int, meta: Types.Meta) -> Result[Parsed]
  c = src.bytes[pos]
  if c == Source.PIPE or c == Source.GREATER
    scanned = try Scanner.block_scalar(src, pos, n)
    return ok(
      Parsed(node: Types.Node.Scalar(meta, false, scanned.text), pos: Source.skip_empty_lines(src, scanned.pos)),
    )
  end

  parsed = try content(src, pos, n, depth, meta, Scanner.Context.Block)
  next_line = try finish_line(src, parsed.pos)
  ok(Parsed(node: parsed.node, pos: next_line))
end

def block_seq(src: Source.Source, pos: Int, m: Int, depth: Int, meta: Types.Meta) -> Result[Parsed]
  return Source.over_limit(src, pos, "nesting deeper than #{src.options.max_depth}") if depth > src.options.max_depth

  items: List[Types.Node] = []
  i = pos
  next_line = pos
  while true
    item = try block_node(src, i + 1, m, Kind.Entry, depth)
    items = items.push(item.node)
    next_line = item.pos
    break if next_line >= src.size or Source.document_marker?(src, next_line)

    first = Source.skip_spaces(src, next_line)
    indent = first - next_line
    break if indent < m
    return Source.fail(src, first, "bad indentation of a sequence entry") if indent > m
    break if src.bytes[first] != Source.DASH or not Source.blank_or_end?(src.bytes[first + 1])

    i = first
  end

  ok(Parsed(node: Types.Node.Seq(placed(meta, pos), items), pos: next_line))
end

def block_map(src: Source.Source, pos: Int, m: Int, depth: Int, meta: Types.Meta) -> Result[Parsed]
  return Source.over_limit(src, pos, "nesting deeper than #{src.options.max_depth}") if depth > src.options.max_depth

  entries: List[Types.Entry] = []
  i = pos
  next_line = pos
  while true
    entry = try block_entry(src, i, m, depth)
    entries = entries.push(Types.Entry(key: entry.key, value: entry.value))
    next_line = entry.pos
    break if next_line >= src.size or Source.document_marker?(src, next_line)

    first = Source.skip_spaces(src, next_line)
    indent = first - next_line
    break if indent < m
    return Source.fail(src, first, "bad indentation of a mapping entry") if indent > m

    i = first
  end

  ok(Parsed(node: Types.Node.Map(placed(meta, pos), entries), pos: next_line))
end

def block_entry(src: Source.Source, pos: Int, m: Int, depth: Int) -> Result[Pair]
  c = src.bytes[pos]
  marker = Source.blank_or_end?(src.bytes[pos + 1])
  if c == Source.QUESTION and marker
    key = try block_node(src, pos + 1, m, Kind.Explicit, depth)
    next_line = key.pos
    if next_line < src.size and not Source.document_marker?(src, next_line)
      first = Source.skip_spaces(src, next_line)
      if first - next_line == m and src.bytes[first] == Source.COLON and Source.blank_or_end?(src.bytes[first + 1])
        value = try block_node(src, first + 1, m, Kind.Explicit, depth)
        return ok(Pair(key: key.node, value: value.node, pos: value.pos))
      end
    end

    return ok(Pair(key: key.node, value: empty(next_line), pos: next_line))
  end

  if c == Source.COLON and marker
    value = try block_node(src, pos + 1, m, Kind.Value, depth)
    return ok(Pair(key: empty(pos), value: value.node, pos: value.pos))
  end

  key = try implicit_key(src, pos, m, depth)
  value = try block_node(src, key.pos, m, Kind.Value, depth)
  ok(Pair(key: key.node, value: value.node, pos: value.pos))
end

def key_on_line?(src: Source.Source, pos: Int, depth: Int) -> Bool
  i = pos
  while src.bytes[i] != Source.COLON
    return false if src.bytes[i] == Source.BREAK or i >= src.size or i - pos > MAX_KEY_LENGTH

    i += 1
  end

  implicit_key(src, pos, -1, depth).ok?
end

# A key of a block mapping: one line, at most 1024 characters, then `:` and a blank. The parsed pos is after the `:`.
def implicit_key(src: Source.Source, pos: Int, n: Int, depth: Int) -> Result[Parsed]
  props = try props(src, pos)
  i = props.pos
  c = src.bytes[i]
  parsed = Parsed(node: empty_with(props.meta), pos: i)
  if c != Source.COLON or not props.found
    parsed = try content(src, i, n, depth, props.meta, Scanner.Context.BlockKey)
  end

  colon = Source.skip_blanks(src, parsed.pos)
  if src.bytes[colon] != Source.COLON or not Source.blank_or_end?(src.bytes[colon + 1])
    return Source.fail(src, colon, "expected ':' after a mapping key")
  end

  return Source.fail(src, pos, "an implicit key is longer than 1024 characters") if colon - pos > MAX_KEY_LENGTH
  if c != Source.STAR and Source.indicator?(c) and line_break?(src, pos, colon)
    return Source.fail(src, pos, "an implicit key must be on one line")
  end

  ok(Parsed(node: parsed.node, pos: colon + 1))
end

def line_break?(src: Source.Source, start: Int, stop: Int) -> Bool
  for i in start...stop
    return true if src.bytes[i] == Source.BREAK
  end

  false
end

def props(src: Source.Source, pos: Int) -> Result[Props]
  anchor = ""
  tag = ""
  found = false
  i = pos
  while true
    c = src.bytes[i]
    if c == Source.AMPERSAND
      return Source.fail(src, i, "a node has one anchor") if anchor != ""

      scanned = try Scanner.anchor(src, i)
      anchor = scanned.text
      i = scanned.pos
    elsif c == Source.BANG
      return Source.fail(src, i, "a node has one tag") if found and tag != ""

      scanned = try Scanner.tag(src, i)
      tag = scanned.text
      i = scanned.pos
    else
      break
    end

    found = true
    i = Source.skip_blanks(src, i)
  end

  ok(Props(meta: Types.Meta(anchor: anchor, tag: tag, pos: pos), found: found, pos: i))
end

# The node at `pos` after its properties: a flow collection, a quoted or plain scalar, or an alias.
def content(
  src: Source.Source,
  pos: Int,
  n: Int,
  depth: Int,
  meta: Types.Meta,
  context: Scanner.Context,
) -> Result[Parsed]
  c = src.bytes[pos]
  meta_here = placed(meta, pos)
  if c == Source.OPEN_BRACKET
    flow_seq(src, pos, n, depth + 1, meta_here)
  elsif c == Source.OPEN_BRACE
    flow_map(src, pos, n, depth + 1, meta_here)
  elsif c == Source.QUOTE
    scanned = try Scanner.double_quoted(src, pos, n)
    ok(Parsed(node: Types.Node.Scalar(meta_here, false, scanned.text), pos: scanned.pos))
  elsif c == Source.APOSTROPHE
    scanned = try Scanner.single_quoted(src, pos, n)
    ok(Parsed(node: Types.Node.Scalar(meta_here, false, scanned.text), pos: scanned.pos))
  elsif c == Source.STAR
    return Source.fail(src, meta.pos, "an alias cannot have an anchor or a tag") if meta.anchor != "" or meta.tag != ""

    scanned = try Scanner.anchor(src, pos)
    ok(Parsed(node: Types.Node.Alias(scanned.text, pos), pos: scanned.pos))
  elsif not Scanner.plain_start?(src, pos, context == Scanner.Context.Flow)
    Source.fail(src, pos, "unexpected #{shown(src, pos)}")
  else
    scanned = try Scanner.plain(src, pos, n, context)
    ok(Parsed(node: Types.Node.Scalar(meta_here, true, scanned.text), pos: scanned.pos))
  end
end

def shown(src: Source.Source, pos: Int) -> String
  c = src.bytes[pos]
  if pos >= src.size
    "end of the text"
  elsif c == Source.BREAK
    "end of the line"
  elsif c == Source.TAB
    "tab"
  else
    "'#{Source.text(src, pos, pos + 1)}'"
  end
end

# Blanks, comments and line breaks inside a flow collection; each line must be indented more than `n`.
def flow_space(src: Source.Source, pos: Int, n: Int) -> Result[Int]
  i = pos
  while true
    i = Source.skip_blanks(src, i)
    c = src.bytes[i]
    if c == Source.HASH
      if i == pos and i > 0 and not Source.blank_or_end?(src.bytes[i - 1])
        return Source.fail(src, i, "a comment needs a space before it")
      end

      i = Source.skip_to_break(src, i)
      c = src.bytes[i]
    end

    return ok(i) if c != Source.BREAK or i >= src.size

    line = i + 1
    return Source.fail(src, line, "a document marker inside a flow collection") if Source.document_marker?(src, line)

    first = Source.skip_spaces(src, line)
    text = Source.skip_blanks(src, first)
    has_text = src.bytes[text] != Source.BREAK and src.bytes[text] != Source.HASH and text < src.size
    return Source.fail(src, text, "bad indentation in a flow collection") if has_text and first - line <= n

    i = line
  end

  ok(i)
end

def flow_end?(src: Source.Source, pos: Int) -> Bool
  c = src.bytes[pos]
  c == Source.COMMA or c == Source.CLOSE_BRACKET or c == Source.CLOSE_BRACE or pos >= src.size
end

def flow_colon?(src: Source.Source, pos: Int) -> Bool
  next_byte = src.bytes[pos + 1]
  src.bytes[pos] == Source.COLON and (Source.blank_or_end?(next_byte) or Source.flow_indicator?(next_byte))
end

# A node inside a flow collection, with its properties.
def flow_node(src: Source.Source, pos: Int, n: Int, depth: Int) -> Result[Parsed]
  props = try props(src, pos)
  i = props.pos
  if props.found
    i = try flow_space(src, i, n)
    return ok(Parsed(node: empty_with(props.meta), pos: i)) if flow_end?(src, i) or flow_colon?(src, i)
  end

  content(src, i, n, depth, props.meta, Scanner.Context.Flow)
end

def flow_value(src: Source.Source, pos: Int, n: Int, depth: Int) -> Result[Parsed]
  i = try flow_space(src, pos, n)
  return ok(Parsed(node: empty(i), pos: i)) if flow_end?(src, i)

  flow_node(src, i, n, depth)
end

def flow_seq(src: Source.Source, pos: Int, n: Int, depth: Int, meta: Types.Meta) -> Result[Parsed]
  return Source.over_limit(src, pos, "nesting deeper than #{src.options.max_depth}") if depth > src.options.max_depth

  items: List[Types.Node] = []
  i = pos + 1
  while true
    i = try flow_space(src, i, n)
    return Source.fail(src, pos, "unterminated flow sequence") if i >= src.size
    return ok(Parsed(node: Types.Node.Seq(meta, items), pos: i + 1)) if src.bytes[i] == Source.CLOSE_BRACKET

    entry = try flow_seq_entry(src, i, n, depth)
    items = items.push(entry.node)
    i = try flow_space(src, entry.pos, n)
    c = src.bytes[i]
    if i >= src.size
      return Source.fail(src, pos, "unterminated flow sequence")
    elsif c == Source.COMMA
      i += 1
    elsif c != Source.CLOSE_BRACKET
      return Source.fail(src, i, "expected ',' or ']'")
    end
  end

  Source.fail(src, pos, "unterminated flow sequence")
end

# An entry of a flow sequence: a node, or a pair (`a: b`, `? a : b`) that is a mapping of one entry.
def flow_seq_entry(src: Source.Source, pos: Int, n: Int, depth: Int) -> Result[Parsed]
  c = src.bytes[pos]
  explicit = c == Source.QUESTION and (Source.blank_or_end?(src.bytes[pos + 1]) or flow_end?(src, pos + 1))
  if explicit or flow_colon?(src, pos)
    pair = try flow_pair(src, pos, n, depth)
    return ok(Parsed(node: single_pair(pair, pos), pos: pair.pos))
  end

  key = try flow_node(src, pos, n, depth)
  colon = Source.skip_blanks(src, key.pos)
  return ok(key) if src.bytes[colon] != Source.COLON

  return Source.fail(src, pos, "an implicit key must be on one line") if line_break?(src, pos, colon)

  value = try flow_value(src, colon + 1, n, depth)
  pair = Pair(key: key.node, value: value.node, pos: value.pos)
  ok(Parsed(node: single_pair(pair, pos), pos: pair.pos))
end

def single_pair(pair: Pair, pos: Int) -> Types.Node
  Types.Node.Map(no_meta(pos), [Types.Entry(key: pair.key, value: pair.value)])
end

def flow_map(src: Source.Source, pos: Int, n: Int, depth: Int, meta: Types.Meta) -> Result[Parsed]
  return Source.over_limit(src, pos, "nesting deeper than #{src.options.max_depth}") if depth > src.options.max_depth

  entries: List[Types.Entry] = []
  i = pos + 1
  while true
    i = try flow_space(src, i, n)
    return Source.fail(src, pos, "unterminated flow mapping") if i >= src.size
    return ok(Parsed(node: Types.Node.Map(meta, entries), pos: i + 1)) if src.bytes[i] == Source.CLOSE_BRACE

    pair = try flow_pair(src, i, n, depth)
    entries = entries.push(Types.Entry(key: pair.key, value: pair.value))
    i = try flow_space(src, pair.pos, n)
    c = src.bytes[i]
    if i >= src.size
      return Source.fail(src, pos, "unterminated flow mapping")
    elsif c == Source.COMMA
      i += 1
    elsif c != Source.CLOSE_BRACE
      return Source.fail(src, i, "expected ',' or '}'")
    end
  end

  Source.fail(src, pos, "unterminated flow mapping")
end

# A pair of a flow collection: an optional `?`, a key (or none), and an optional `:` and value.
def flow_pair(src: Source.Source, pos: Int, n: Int, depth: Int) -> Result[Pair]
  i = pos
  if src.bytes[i] == Source.QUESTION and (Source.blank_or_end?(src.bytes[i + 1]) or flow_end?(src, i + 1))
    i = try flow_space(src, i + 1, n)
  end

  key = Parsed(node: empty(i), pos: i)
  if not flow_colon?(src, i) and not flow_end?(src, i)
    key = try flow_node(src, i, n, depth)
  end

  colon = try flow_space(src, key.pos, n)
  return ok(Pair(key: key.node, value: empty(key.pos), pos: key.pos)) if src.bytes[colon] != Source.COLON

  value = try flow_value(src, colon + 1, n, depth)
  ok(Pair(key: key.node, value: value.node, pos: value.pos))
end

## The names of RFC 1035 3.1 and 4.1.4: labels of at most 63 bytes, at most 255 bytes in all, written as text, and read
## with the compression pointers of a message. Everything here is a pure function on `Bytes` and `String`.
##
## A name as text has its labels joined with dots and no final dot, and "" is the root. A dot or a backslash inside a
## label is written after a backslash, and a byte outside the printable ASCII range (the space included) as `\DDD`, its
## decimal value in three digits (RFC 4343 2.1), so any name has one text and the text holds only ASCII.

import Types from "types"

## The most bytes of a label.
MAX_LABEL_BYTES = 63

## The most bytes of a name on the wire, the length bytes and the end byte included.
MAX_NAME_BYTES = 255

## The most compression pointers that one name may follow.
MAX_POINTERS = 32

## A name read from a message: its text, and the offset after it, where the next field starts. A name that ends with a
## pointer ends after the two bytes of that pointer.
struct Read
  name: String
  next: Int
end

## A name that was read, by the offset where it starts. Its `text` is the whole name, the pointers followed. `size` is
## what the name takes on the wire without pointers, `pointers` how many it follows, and `first` where the first of
## them goes (-1 for none): the name may be the end of another one only if that is before the other.
struct Entry
  text: String
  size: Int
  pointers: Int
  next: Int
  first: Int
end

## The names read so far in one message, by offset. A pointer must go before the name that holds it, so what a name
## reads after its first pointer depends on the target alone: a message of many records that point at one long name
## pays for that name once.
struct Names
  entries: Map[Int, Entry] = {}
end

## The name that `read` found, and the names to pass to the next `read` of the same message.
struct Found
  entry: Entry
  names: Names
end

## Reads the name at `offset` of the message. An error for a name that runs past the data, a label type that the RFC
## reserves, a pointer into the header or one that does not go before the name that holds it (so a name never reads a
## byte twice, and a loop cannot happen), more than 32 pointers and a name over 255 bytes.
def decode(data: Bytes, offset: Int) -> Result[Read]
  found = try read(data, offset, Names())
  ok(Read(name: found.entry.text, next: found.entry.next))
end

## Reads the name at `offset` like `decode`, with the names that the same message gave before.
def read(data: Bytes, offset: Int, names: Names) -> Result[Found] = read_at(data, offset, names, 0)

## The bytes of a name: each label with its length, then the zero that ends it. An error for an empty label (`a..b`),
## a label over 63 bytes, a name over 255 bytes and a `\` that is followed by nothing or by a number over 255.
def encode(name: String) -> Result[Bytes]
  labels = try split(name)
  parts: List[Bytes] = []
  total = 1
  for label in labels
    return malformed("a label of #{name} is empty") if label.empty?
    return malformed("a label of #{name} is over #{MAX_LABEL_BYTES} bytes") if label.size > MAX_LABEL_BYTES
    total += label.size + 1
    parts = parts.push(Bytes.from_list([label.size]).unwrap!).push(label)
  end

  return malformed("#{name} is over #{MAX_NAME_BYTES} bytes") if total > MAX_NAME_BYTES
  ok(Bytes.concat(parts.push(Bytes.from_list([0]).unwrap!)))
end

## Returns true when two names are the same: they have the same bytes on the wire once the letters A to Z are lower
## case, as DNS compares them (RFC 4343). So `example.com.` is `example.com`, `\065` is `a`, and a text that does not
## encode is the same as nothing.
def same?(a: String, b: String) -> Bool
  left = encode(a)
  right = encode(b)
  return false if not left.ok? or not right.ok?
  ascii_lower(left.unwrap!) == ascii_lower(right.unwrap!)
end

private

# The two top bits of a length byte: 11 is a pointer, 01 and 10 are reserved.
POINTER = 192
HEADER_BYTES = 12
BACKSLASH = 92
DOT = 46
DIGIT_ZERO = 48
DIGIT_NINE = 57
PRINTABLE_FIRST = 33
PRINTABLE_LAST = 126
UPPER_A = 65
UPPER_Z = 90
CASE_GAP = 32

# A byte that a backslash stands for, and how many bytes after the backslash it took.
struct Escape
  byte: Int
  used: Int
end

def read_at(data: Bytes, offset: Int, names: Names, depth: Int) -> Result[Found]
  return checked(names.entries[offset], names, depth) if names.entries.has_key?(offset)

  starts: List[Int] = []
  labels: List[String] = []
  lengths: List[Int] = []
  position = offset
  size = 0
  tail = ""
  base = 1
  pointers = 0
  after = 0
  jump = -1
  known = names
  while true
    return malformed("a name runs past the end of the message") if position >= data.size
    if position != offset and known.entries.has_key?(position) and known.entries[position].first < offset
      # The rest of this name is a name that was read before, at a place that is not a label start of this one.
      ahead = known.entries[position]
      tail = ahead.text
      base = ahead.size
      pointers = ahead.pointers
      after = ahead.next
      jump = ahead.first
      break
    end

    first = data[position]
    if first == 0
      after = position + 1
      break
    elsif first >= POINTER
      return malformed("a name runs past the end of the message") if position + 1 >= data.size
      target = (first - POINTER) * 256 + data[position + 1]
      return malformed("a compression pointer must go before its name") if target >= offset or target < HEADER_BYTES
      return malformed("a name has more than #{MAX_POINTERS} compression pointers") if depth >= MAX_POINTERS
      found = try read_at(data, target, known, depth + 1)
      known = found.names
      tail = found.entry.text
      base = found.entry.size
      pointers = found.entry.pointers + 1
      after = position + 2
      jump = target
      break
    elsif first > MAX_LABEL_BYTES
      return malformed("a label has a reserved type")
    else
      return malformed("a label runs past the end of the message") if position + 1 + first > data.size
      size += first + 1
      return malformed("a name is over #{MAX_NAME_BYTES} bytes") if size > MAX_NAME_BYTES
      starts = starts.push(position)
      labels = labels.push(escaped(data.slice(position + 1, first)))
      lengths = lengths.push(first + 1)
      position += first + 1
    end
  end

  # Every label start is a name of its own, which a later pointer may name: it ends where this one does.
  text = tail
  total = base
  entries = known.entries
  top = Entry(text: tail, size: base, pointers: pointers, next: after, first: jump)
  index = labels.length - 1
  while index >= 0
    text = joined([labels[index]], text)
    total += lengths[index]
    top = Entry(text: text, size: total, pointers: pointers, next: after, first: jump)
    entries = entries.put(starts[index], top)
    index -= 1
  end

  if labels.empty?
    entries = entries.put(offset, top)
  end

  return malformed("a name is over #{MAX_NAME_BYTES} bytes") if top.size > MAX_NAME_BYTES
  checked(top, Names(entries: entries), depth)
end

# A name that was read before still has to fit where it is read now: the pointers add up along the way.
def checked(entry: Entry, names: Names, depth: Int) -> Result[Found]
  return malformed("a name is over #{MAX_NAME_BYTES} bytes") if entry.size > MAX_NAME_BYTES
  if depth + entry.pointers > MAX_POINTERS
    return malformed("a name has more than #{MAX_POINTERS} compression pointers")
  end

  ok(Found(entry: entry, names: names))
end

def joined(labels: List[String], tail: String) -> String
  own = labels.join(".")
  return tail if own == ""
  return own if tail == ""
  "#{own}.#{tail}"
end

def malformed[T](message: String) -> Result[T] = error("dns: #{message}", kind: Types.MALFORMED)

# Lower case for A to Z only: String.downcase would change letters that DNS does not.
# The length bytes of a name are under 64, so they are never in the range of A to Z.
def ascii_lower(data: Bytes) -> Bytes = Bytes.from_list(data.to_a.map { |b| lower(b) }).unwrap!

def lower(byte: Int) -> Int
  return byte + CASE_GAP if byte >= UPPER_A and byte <= UPPER_Z

  byte
end

def escaped(label: Bytes) -> String
  pieces = label.to_a.map { |b| escape(b) }
  pieces.join("")
end

def escape(byte: Int) -> String
  if byte == DOT or byte == BACKSLASH
    "\\#{String.from_code(byte)}"
  elsif byte >= PRINTABLE_FIRST and byte <= PRINTABLE_LAST
    String.from_code(byte)
  else
    "\\#{decimal(byte)}"
  end
end

def decimal(byte: Int) -> String
  digits = byte.to_s
  "0" * (3 - digits.length) + digits
end

# The labels of a name as text, each as its bytes. A final dot is allowed once; "" and "." are the root.
def split(name: String) -> Result[List[Bytes]]
  bytes = name.bytes.to_a
  return ok([]) if bytes.size == 0 or (bytes.size == 1 and bytes[0] == DOT)
  labels: List[Bytes] = []
  current: List[Int] = []
  index = 0
  while index < bytes.size
    byte = bytes[index]
    if byte == DOT
      labels = labels.push(Bytes.from_list(current).unwrap!)
      current = []
    elsif byte == BACKSLASH
      step = try unescape(bytes, index + 1)
      current = current.push(step.byte)
      index += step.used
    else
      current = current.push(byte)
    end

    index += 1
  end

  if current.size > 0 or bytes[bytes.size - 1] != DOT
    labels = labels.push(Bytes.from_list(current).unwrap!)
  end

  ok(labels)
end

# What follows a backslash at `index`: three digits are a byte, any other byte stands for itself.
def unescape(bytes: List[Int], index: Int) -> Result[Escape]
  return malformed("a name ends with a backslash") if index >= bytes.size
  if bytes[index] >= DIGIT_ZERO and bytes[index] <= DIGIT_NINE
    return malformed("a \\ must be followed by three digits") if index + 2 >= bytes.size
    digits = bytes.drop(index).take(3)
    non_digit = digits.any? do |d| d < DIGIT_ZERO or d > DIGIT_NINE end
    return malformed("a \\ must be followed by three digits") if non_digit
    value = (digits[0] - DIGIT_ZERO) * 100 + (digits[1] - DIGIT_ZERO) * 10 + digits[2] - DIGIT_ZERO
    return malformed("a \\ number is over 255") if value > 255
    return ok(Escape(byte: value, used: 3))
  end

  ok(Escape(byte: bytes[index], used: 1))
end

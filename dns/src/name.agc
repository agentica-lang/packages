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

## The most compression pointers that one name may follow. A pointer must go back, so a name always ends; this bounds
## the work of a hostile message that chains pointers.
MAX_POINTERS = 32

## A name read from a message: its text, and the offset after it, where the next field starts. A name that ends with a
## pointer ends after the two bytes of the first pointer.
struct Read
  name: String
  next: Int
end

## Reads the name at `offset` of the message. An error for a name that runs past the data, a label type that the RFC
## reserves, a pointer that does not go back, too many pointers and a name over 255 bytes.
def decode(data: Bytes, offset: Int) -> Result[Read]
  labels: List[String] = []
  position = offset
  after = -1
  pointers = 0
  total = 1
  while true
    return malformed("a name runs past the end of the message") if position >= data.size
    first = data[position]
    if first == 0
      if after < 0
        after = position + 1
      end

      break
    elsif first >= POINTER
      return malformed("a name runs past the end of the message") if position + 1 >= data.size
      target = (first - POINTER) * 256 + data[position + 1]
      return malformed("a compression pointer must go back") if target >= position
      pointers += 1
      return malformed("a name has more than #{MAX_POINTERS} compression pointers") if pointers > MAX_POINTERS
      if after < 0
        after = position + 2
      end

      position = target
    elsif first > MAX_LABEL_BYTES
      return malformed("a label has a reserved type")
    else
      return malformed("a label runs past the end of the message") if position + 1 + first > data.size
      total += first + 1
      return malformed("a name is over #{MAX_NAME_BYTES} bytes") if total > MAX_NAME_BYTES
      labels = labels.push(escaped(data.slice(position + 1, first)))
      position += first + 1
    end
  end

  ok(Read(name: labels.join("."), next: after))
end

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

## Returns true when two names are the same: DNS compares the letters A to Z without case (RFC 4343).
def same?(a: String, b: String) -> Bool = ascii_lower(a) == ascii_lower(b)

private

# The two top bits of a length byte: 11 is a pointer, 01 and 10 are reserved.
POINTER = 192
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

def malformed[T](message: String) -> Result[T] = error("dns: #{message}", kind: Types.MALFORMED)

# Lower case for A to Z only: String.downcase would change letters that DNS does not.
def ascii_lower(text: String) -> Bytes = Bytes.from_list(text.bytes.to_a.map { |b| lower(b) }).unwrap!

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

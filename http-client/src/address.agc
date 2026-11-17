## IP addresses as text: which are IP literals, and which are public, for the `public_only` filter of the client.
##
## Not public: unspecified, loopback, private, carrier-grade NAT, link-local, documentation, benchmarking, multicast
## and reserved ranges of the IANA special-purpose registries (RFC 6890 and its updates). An IPv6 address that carries
## an IPv4 one (mapped `::ffff:0:0/96`, NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) is judged by that IPv4 address.

## The bytes of an IPv4 (4) or IPv6 (16) address written as text, without brackets or a zone; none for anything else.
def parse(text: String) -> Optional[List[Int]]
  return parse_v6(text) if text.include?(":")

  parse_v4(text)
end

## Whether `host` (a URL host, an IPv6 one in brackets) is an IP literal rather than a name.
def literal?(host: String) -> Bool = parse(unbracketed(host)).some?

## `host` without the brackets of an IPv6 literal.
def unbracketed(host: String) -> String
  return host.slice(1, host.length - 2) if host.start_with?("[") and host.end_with?("]")

  host
end

## Whether the address is public: a global unicast one. Text that is not an IP address is not public.
def public?(text: String) -> Bool
  case parse(text)
    some(bytes) if bytes.size == 4 -> public_v4?(bytes)
    some(bytes) -> public_v6?(bytes)
    none -> false
  end
end

private

# IPv4 ranges that are not public, as [first byte, second byte or -1, third byte or -1, prefix length].
V4_RANGES = [
  [0, -1, -1, 8],
  [10, -1, -1, 8],
  [100, 64, -1, 10],
  [127, -1, -1, 8],
  [169, 254, -1, 16],
  [172, 16, -1, 12],
  [192, 0, 0, 24],
  [192, 0, 2, 24],
  [192, 88, 99, 24],
  [192, 168, -1, 16],
  [198, 18, -1, 15],
  [198, 51, 100, 24],
  [203, 0, 113, 24],
  [224, -1, -1, 4],
  [240, -1, -1, 4],
]

def public_v4?(bytes: List[Int]) -> Bool = not V4_RANGES.any? { |range| in_v4?(bytes, range) }

def in_v4?(bytes: List[Int], range: List[Int]) -> Bool
  prefix = range[3]
  address = ((bytes[0] * 256 + bytes[1]) * 256 + bytes[2]) * 256 + bytes[3]
  start = ((range[0] * 256 + [range[1], 0].max.unwrap!) * 256 + [range[2], 0].max.unwrap!) * 256
  size = 1
  for _ in 1..(32 - prefix)
    size = size * 2
  end

  address >= start and address < start + size
end

def public_v6?(bytes: List[Int]) -> Bool
  first = bytes[0] * 256 + bytes[1]
  second = bytes[2] * 256 + bytes[3]
  zeros = zero?(bytes.take(10))
  # ::/128, ::1 and the rest of ::/96 (IPv4-compatible, deprecated).
  return false if zeros and bytes[10] == 0 and bytes[11] == 0
  return public_v4?(bytes.drop(12)) if zeros and bytes[10] == 255 and bytes[11] == 255
  return public_v4?(bytes.drop(12)) if first == 0x64 and second == 0xff9b and zero?(bytes.drop(4).take(8))
  return public_v4?(bytes.drop(2).take(4)) if first == 0x2002
  # 64:ff9b:1::/48 (local NAT64), 100::/64 (discard), 2001::/23 (IETF protocols, Teredo among them), 2001:db8::/32
  # and 3fff::/20 (documentation), fc00::/7 (unique local), fe80::/10 (link-local), fec0::/10 (site-local),
  # ff00::/8 (multicast).
  return false if first == 0x64 and second == 0xff9b
  return false if first == 0x100 and zero?(bytes.drop(2).take(6))
  return false if first == 0x2001 and (second < 0x200 or second == 0xdb8)
  return false if first == 0x3fff and second < 0x1000
  return false if first >= 0xfc00

  first >= 0x2000 and first < 0x4000
end

def zero?(bytes: List[Int]) -> Bool = bytes.all? { |byte| byte == 0 }

def digits?(text: String) -> Bool = text.bytes.to_a.all? { |byte| byte >= 48 and byte <= 57 }

def parse_v4(text: String) -> Optional[List[Int]]
  parts = text.split(".")
  return none if parts.size != 4

  bytes = parts.map { |part| decimal(part) }
  return none if bytes.min.unwrap_or(-1) < 0 or bytes.max.unwrap_or(256) > 255

  some(bytes)
end

# A decimal byte as `inet_pton` reads it: one to three digits, no sign and no leading zero; -1 when it is not one.
def decimal(text: String) -> Int
  return -1 if text.empty? or text.length > 3 or (text.length > 1 and text.start_with?("0"))
  return -1 if not digits?(text)

  text.to_i.unwrap_or(-1)
end

def parse_v6(text: String) -> Optional[List[Int]]
  halves = text.split("::")
  return none if halves.size > 2

  head = groups(halves[0])
  tail: Optional[List[Int]] = some([])
  if halves.size == 2
    tail = groups(halves[1])
  end

  return none if not head.some? or not tail.some?

  front = head.unwrap!
  back = tail.unwrap!
  if halves.size == 1
    return none if front.size != 16

    return some(front)
  end

  return none if front.size + back.size > 14

  some(front + (1..(16 - front.size - back.size)).to_a.map { |_| 0 } + back)
end

# The bytes of colon-separated hex groups, the last of which may be an IPv4 address; none when one is bad.
def groups(text: String) -> Optional[List[Int]]
  return some([]) if text.empty?

  parts = text.split(":")
  bytes: List[Int] = []
  for at in 0..(parts.size - 1)
    part = parts[at]
    if at == parts.size - 1 and part.include?(".")
      case parse_v4(part)
        some(v4) -> bytes = bytes + v4
        none -> return none
      end
    else
      value = hex(part)
      return none if value < 0

      bytes = bytes + [value / 256, value % 256]
    end
  end

  some(bytes)
end

# A group of one to four hex digits, or -1.
def hex(text: String) -> Int
  return -1 if text.empty? or text.length > 4

  value = 0
  for byte in text.downcase.bytes
    digit = -1
    if byte >= 48 and byte <= 57
      digit = byte - 48
    elsif byte >= 97 and byte <= 102
      digit = byte - 87
    end

    return -1 if digit < 0

    value = value * 16 + digit
  end

  value
end

## The nameservers of the system, read from a `resolv.conf` (resolv.conf(5)). Nothing here runs unless the program
## asks.

import Types from "types"

## The most nameservers that are taken from the file, as the C library does.
MAX_SERVERS = 3

## The nameservers of the text of a `resolv.conf`, as TCP servers on port 53, in order, at most 3. A line is
## `nameserver ADDRESS`; the keyword is read without case, an address with a zone (`fe80::1%eth0`) is skipped, and any
## other line (a comment, `search`, `options`) is ignored.
def parse(text: String) -> List[Types.Server]
  servers: List[Types.Server] = []
  for line in text.split("\n")
    address = address_of(line)
    if address != "" and servers.length < MAX_SERVERS
      servers = servers.push(Types.Server.Tcp(address, PORT))
    end
  end

  servers
end

## The nameservers of the file at `path`. An `error` when it cannot be read and of the kind `dns.malformed` when it has
## no nameserver.
def read(path: String) -> Result[List[Types.Server]]
  text = try File.read_text(path)
  servers = parse(text)
  return error("dns: #{path} has no nameserver", kind: Types.MALFORMED) if servers.empty?
  ok(servers)
end

private

PORT = 53
KEYWORD = "nameserver"
# Tab, vertical tab, form feed and carriage return (a line ends at the line feed).
WHITE_SPACE = [9, 11, 12, 13]
IPV4_PARTS = 4
IPV6_GROUPS = 8
DIGIT_ZERO = 48
DIGIT_NINE = 57
UPPER_A = 65
UPPER_F = 70
LOWER_A = 97
LOWER_F = 102

def address_of(line: String) -> String
  fields = separated(line.split("#").first.split(";").first)
  return "" if fields.length < 2 or fields[0].downcase != KEYWORD
  return "" if not ip?(fields[1])
  fields[1]
end

# The words of a line: any white space separates them, the CR of a CRLF file too.
def separated(line: String) -> List[String]
  spaced = line
  for code in WHITE_SPACE
    spaced = spaced.replace(String.from_code(code), " ")
  end

  spaced.split(" ").select { |word| word != "" }
end

# An IP literal as `inet_pton` reads it: a name, a zone (`%eth0`) and anything else is not one.
def ip?(text: String) -> Bool = ipv4?(text) or ipv6?(text)

def ipv4?(text: String) -> Bool
  parts = text.split(".")
  return false if parts.length != IPV4_PARTS
  parts.all? do |part| octet?(part) end
end

def octet?(part: String) -> Bool
  return false if part.empty? or part.length > 3 or not digits?(part)
  return false if part.length > 1 and part.start_with?("0")
  part.to_i! <= 255
end

def digits?(text: String) -> Bool = text.bytes.to_a.all? do |b| b >= DIGIT_ZERO and b <= DIGIT_NINE end

def hex_digits?(text: String) -> Bool = text.bytes.to_a.all? do |b| hex_digit?(b) end

def hex_digit?(b: Int) -> Bool
  (b >= DIGIT_ZERO and b <= DIGIT_NINE) or (b >= LOWER_A and b <= LOWER_F) or (b >= UPPER_A and b <= UPPER_F)
end

# Groups of 1 to 4 hex digits, 8 of them, or fewer with one `::`; the last group may be an IPv4 address, which is two.
def ipv6?(text: String) -> Bool
  return false if not text.include?(":")

  case text.index_of("::")
    none ->
      parts = text.split(":")
      groups?(parts, true) and places(parts) == IPV6_GROUPS
    some(gap) ->
      tail = text.slice(gap + 2, text.length - gap - 2)
      return false if tail.include?("::")

      before = parts_of(text.slice(0, gap))
      after = parts_of(tail)
      groups?(before, false) and groups?(after, true) and places(before) + places(after) < IPV6_GROUPS
  end
end

def parts_of(text: String) -> List[String]
  return [] if text == ""

  text.split(":")
end

def groups?(groups: List[String], may_end_with_ipv4: Bool) -> Bool
  index = 0
  for group in groups
    ending = index == groups.length - 1
    return false if not group_ok?(group) and not (ending and may_end_with_ipv4 and ipv4?(group))

    index += 1
  end

  true
end

def group_ok?(group: String) -> Bool = group.length >= 1 and group.length <= 4 and hex_digits?(group)

# The 16-bit places that the groups take: an IPv4 address takes two.
def places(groups: List[String]) -> Int
  total = 0
  for group in groups
    total += 1
    if group.include?(".")
      total += 1
    end
  end

  total
end

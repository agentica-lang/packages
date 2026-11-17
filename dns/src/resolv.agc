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

def address_of(line: String) -> String
  fields = line.split("#").first.split(";").first.replace("\t", " ").split(" ").select { |f| f != "" }
  return "" if fields.length < 2 or fields[0].downcase != KEYWORD
  return "" if fields[1].include?("%")
  fields[1]
end

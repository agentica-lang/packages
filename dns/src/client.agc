## The asking: one query to the nameservers in order, the checks of the answer, and the CNAME chains.

import Name from "name"
import Transport from "transport"
import Types from "types"
import Wire from "wire"

## The most CNAMEs that `Options.max_cnames` may allow.
MAX_CNAMES = 32

## The most nameservers of a resolver.
MAX_SERVERS = 16

## Makes a resolver. An `error` for no server, more than 16, a server with no host or a port outside 1 to 65535, a
## timeout outside 1 to `MAX_TIMEOUT_MS`, `max_cnames` outside 0 to 32, and, when a server is `Tls`, a system trust
## that cannot be loaded.
def resolver(servers: List[Types.Server], options: Types.Options) -> Result[Types.Resolver]
  return malformed("a resolver needs at least one nameserver") if servers.empty?
  return malformed("a resolver has at most #{MAX_SERVERS} nameservers") if servers.length > MAX_SERVERS
  for server in servers
    try check_server(server)
  end

  if options.timeout_ms < 1 or options.timeout_ms > Types.MAX_TIMEOUT_MS
    return malformed("timeout_ms must be from 1 to #{Types.MAX_TIMEOUT_MS}")
  end

  if options.max_cnames < 0 or options.max_cnames > MAX_CNAMES
    return malformed("max_cnames must be from 0 to #{MAX_CNAMES}")
  end

  ok(Types.Resolver(servers: servers, options: options, context: try context_of(servers, options)))
end

## Asks the nameservers in order until one gives an answer, and returns that message, checked: it is a response to this
## query (the id, the question and the QR flag), it is not cut, and its code is NOERROR. NXDOMAIN ends the search; any
## other failure (a timeout, SERVFAIL, REFUSED, a cut or bad answer) goes on to the next nameserver, and when all fail
## the `error` of the last one is the result.
def query(resolver: Types.Resolver, name: String, type: Int) -> Result[Types.Message]
  last: Result[Types.Message] = malformed("a resolver needs at least one nameserver")
  for server in resolver.servers
    case ask(resolver, server, name, type)
      ok(message) -> return ok(message)
      error(e) ->
        return error(e) if e.is_a?(Types.NXDOMAIN)

        last = error(e)
    end
  end

  last
end

## The addresses of `type` (`TYPE_A` or `TYPE_AAAA`) of a name, with the CNAMEs followed: the ones that the answer
## holds, and, when the chain leaves the answer, a new query for its end. An empty list for a name that exists and has
## no address of that type; an `error` of the kind `dns.cname_limit` for too many CNAMEs or a loop of them.
def addresses(resolver: Types.Resolver, name: String, type: Int) -> Result[List[Types.Address]]
  return malformed("addresses takes TYPE_A or TYPE_AAAA") if type != Types.TYPE_A and type != Types.TYPE_AAAA

  current = name
  hops = 0
  ttl = NO_TTL
  while true
    message = try query(resolver, current, type)
    walked = try walk(message.answers, current, resolver.options.max_cnames - hops)
    hops += walked.followed
    ttl = smaller(ttl, walked.ttl)
    found = addresses_of(message.answers, walked.last, type, ttl)
    return ok(found) if not found.empty?
    return ok([]) if walked.followed == 0

    current = walked.last
  end

  ok([])
end

## The addresses of a host as text, the IPv4 ones first and then the IPv6 ones: the shape of the `resolver:` of
## http-client. The A query goes first; when the name does not exist the AAAA query is not made. One kind that fails
## does not hide the other, but when there is no address the `error` is the one that failed (the A one first), and
## `dns.no_address` when both were answered with none.
##
## The time is bounded: each query takes at most one `timeout_ms` for each nameserver, and each CNAME that leaves an
## answer adds one more query, so `lookup` takes at most `2 * (max_cnames + 1) * servers * timeout_ms`.
def lookup(resolver: Types.Resolver, host: String) -> Result[List[String]]
  four = addresses(resolver, host, Types.TYPE_A)
  case four
    error(e) -> return error(e) if e.is_a?(Types.NXDOMAIN)
    ok(_) -> nil
  end

  six = addresses(resolver, host, Types.TYPE_AAAA)
  nothing: List[Types.Address] = []
  found = four.unwrap_or(nothing) + six.unwrap_or(nothing)
  if found.empty?
    case four
      error(e) -> return error(e)
      ok(_) -> nil
    end

    case six
      error(e) -> return error(e)
      ok(_) -> nil
    end

    return error("dns: #{host} has no address", kind: Types.NO_ADDRESS)
  end

  ok(found.map { |a| a.address })
end

private

# A TTL that no record has: the top of the 32 bits.
NO_TTL = 4_294_967_295

struct Walked
  last: String
  ttl: Int
  followed: Int
end

def malformed[T](message: String) -> Result[T] = error("dns: #{message}", kind: Types.MALFORMED)

def smaller(a: Int, b: Int) -> Int
  return a if a < b

  b
end

def check_server(server: Types.Server) -> Result[Void]
  case server
    Types.Server.Tcp(host, port) -> check_endpoint(host, port)
    Types.Server.Tls(host, port, _) -> check_endpoint(host, port)
  end
end

def check_endpoint(host: String, port: Int) -> Result[Void]
  return malformed("a nameserver needs a host") if host == ""
  return malformed("the port of a nameserver must be from 1 to 65535") if port < 1 or port > 65_535
  ok()
end

# The trust is loaded only when a server needs it.
def context_of(servers: List[Types.Server], options: Types.Options) -> Result[Optional[TLS.Context]]
  case options.tls
    some(context) -> return ok(some(context))
    none -> nil
  end

  needed = servers.any? do |server| secure?(server) end
  return ok(none) if not needed

  ok(some(try TLS.client_context(TLS.ClientOptions())))
end

def secure?(server: Types.Server) -> Bool
  case server
    Types.Server.Tls(_, _, _) -> true
    Types.Server.Tcp(_, _) -> false
  end
end

def ask(resolver: Types.Resolver, server: Types.Server, name: String, type: Int) -> Result[Types.Message]
  id = try random_id()
  query = try Wire.encode_query(id, name, type)
  answer = try Transport.exchange(server, query, resolver.options.timeout_ms, resolver.context)
  message = try Wire.decode(answer)
  try check_answer(message, id, name, type)
  try check_code(message)
  ok(message)
end

def random_id() -> Result[Int]
  bytes = OpenSSL.Random.random_bytes(2)
  ok(bytes[0] * 256 + bytes[1])
end

# The answer must be a response to this query. A server that fails may leave out the question; NOERROR and NXDOMAIN,
# which say something about the name, must have it.
def check_answer(message: Types.Message, id: Int, name: String, type: Int) -> Result[Void]
  return mismatch("the id of the answer is not the id of the query") if message.id != id
  return mismatch("the answer is not a response") if not message.response
  return ok() if message.questions.empty? and may_lack_question?(message.rcode)

  return mismatch("the answer has #{message.questions.length} questions, not 1") if message.questions.length != 1
  asked = message.questions[0]
  if asked.type != type or asked.class != Types.CLASS_IN or not Name.same?(asked.name, name)
    return mismatch("the question of the answer is not the one asked")
  end

  ok()
end

def may_lack_question?(rcode: Int) -> Bool = rcode != Types.RCODE_NOERROR and rcode != Types.RCODE_NXDOMAIN

def mismatch[T](message: String) -> Result[T] = error("dns: #{message}", kind: Types.MISMATCH)

def check_code(message: Types.Message) -> Result[Void]
  return error("dns: the answer is cut", kind: Types.TRUNCATED) if message.truncated

  return ok() if message.rcode == Types.RCODE_NOERROR
  if message.rcode == Types.RCODE_NXDOMAIN
    return error("dns: the name does not exist (NXDOMAIN)", kind: Types.NXDOMAIN)
  end

  if message.rcode == Types.RCODE_REFUSED
    return error("dns: the server refused the query (REFUSED)", kind: Types.REFUSED)
  end

  return error("dns: the server failed (SERVFAIL)", kind: Types.SERVFAIL) if message.rcode == Types.RCODE_SERVFAIL

  error("dns: the server answered with the code #{message.rcode}", kind: Types.SERVFAIL)
end

# Follows the CNAMEs of the answer from `start`, at most `limit` of them. A CNAME whose owner is the name that the
# chain has reached is the next link.
def walk(answers: List[Types.Record], start: String, limit: Int) -> Result[Walked]
  current = start
  ttl = NO_TTL
  followed = 0
  while true
    link = cname_of(answers, current)
    case link
      some(record) ->
        followed += 1
        return error("dns: more than #{limit} CNAMEs for #{start}", kind: Types.CNAME_LIMIT) if followed > limit

        ttl = smaller(ttl, record.ttl)
        current = target_of(record)
      none -> break
    end
  end

  ok(Walked(last: current, ttl: ttl, followed: followed))
end

def cname_of(answers: List[Types.Record], owner: String) -> Optional[Types.Record]
  for record in answers
    if record.type == Types.TYPE_CNAME and record.class == Types.CLASS_IN and Name.same?(record.name, owner)
      return some(record)
    end
  end

  none
end

def target_of(record: Types.Record) -> String
  case record.data
    Types.Data.Cname(name) -> name
    _ -> ""
  end
end

def addresses_of(answers: List[Types.Record], owner: String, type: Int, ttl: Int) -> List[Types.Address]
  found: List[Types.Address] = []
  for record in answers
    if record.type == type and record.class == Types.CLASS_IN and Name.same?(record.name, owner)
      text = address_text(record.data)
      if text != ""
        found = found.push(Types.Address(address: text, type: type, ttl: smaller(ttl, record.ttl)))
      end
    end
  end

  found
end

def address_text(data: Types.Data) -> String
  case data
    Types.Data.A(address) -> address
    Types.Data.Aaaa(address) -> address
    _ -> ""
  end
end

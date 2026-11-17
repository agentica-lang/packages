## The URL of a request, read against the `base_url` of the client: the origin that picks the pool, and the target
## that the request line names.

## Where a request goes. `origin` (`scheme://host:port`) is what `HTTP.start` takes, and `target` is the path with its
## query.
struct Target
  scheme: String
  host: String
  port: Int
  origin: String
  target: String
end

## Reads `url` as it is when it starts with `http://` or `https://`, else as a path (or a `?query`) joined to
## `base_url`. A fragment is dropped. User info in the URL, another scheme, a bad port or an empty host is an
## `argument` error.
def resolve(base_url: String, url: String) -> Result[Target]
  return parse(url) if absolute?(url)

  if base_url.empty?
    return error("http_client: #{url} is not an absolute URL, and the client has no base_url", kind: "argument")
  end

  parse(join(base_url, url))
end

## The URL written back whole, as the response names it.
def to_s(target: Target) -> String = "#{target.origin}#{target.target}"

private

DEFAULT_PORTS = {"http": 80, "https": 443}
MAX_PORT = 65_535

struct HostPort
  host: String
  port: Int
end

# A URL with a scheme of its own, `http` or another (which `parse` refuses), as opposed to a path that may hold `://`
# in its query.
def absolute?(url: String) -> Bool
  case url.index_of("://")
    some(at) -> not first_of(url.slice(0, at), ["/", "?", "#"]).some?
    none -> false
  end
end

def join(base_url: String, url: String) -> String
  return base_url if url.empty?
  return "#{base_url}#{url}" if url.start_with?("?")

  base = base_url
  if base.end_with?("/")
    base = base.slice(0, base.length - 1)
  end

  return "#{base}#{url}" if url.start_with?("/")

  "#{base}/#{url}"
end

def parse(url: String) -> Result[Target]
  scheme_end = try found(url.index_of("://"), "#{url} has no scheme")
  scheme = url.slice(0, scheme_end).downcase
  default_port = try found(DEFAULT_PORTS.get(scheme), "#{url} is not an http or https URL")
  rest = before(url.slice(scheme_end + 3, url.length - scheme_end - 3), "#")
  authority_end = first_of(rest, ["/", "?"]).unwrap_or(rest.length)
  authority = rest.slice(0, authority_end)
  return argument("user info in a URL is not sent; give the client headers instead") if authority.include?("@")

  host_port = try split_host(authority, default_port)
  path = rest.slice(authority_end, rest.length - authority_end)
  if not path.start_with?("/")
    path = "/#{path}"
  end

  ok(
    Target(
      scheme: scheme,
      host: host_port.host,
      port: host_port.port,
      origin: "#{scheme}://#{host_port.host}:#{host_port.port}",
      target: path,
    ),
  )
end

def split_host(authority: String, default_port: Int) -> Result[HostPort]
  host = authority
  port_text = ""
  if authority.start_with?("[")
    close = try found(authority.index_of("]"), "#{authority} has no closing ]")
    host = authority.slice(0, close + 1)
    port_text = authority.slice(close + 1, authority.length - close - 1)
    return argument("bad host #{authority}") if not port_text.empty? and not port_text.start_with?(":")
  else
    case authority.index_of(":")
      some(colon) ->
        host = authority.slice(0, colon)
        port_text = authority.slice(colon, authority.length - colon)
      none -> nil
    end
  end

  return argument("the URL has no host") if host.empty? or host == "[]"

  port = default_port
  if port_text.length > 1
    port = try port_number(port_text.slice(1, port_text.length - 1))
  end

  ok(HostPort(host: host.downcase, port: port))
end

def port_number(text: String) -> Result[Int]
  case text.to_i
    ok(port) if port >= 1 and port <= MAX_PORT and text.length <= 5 -> ok(port)
    _ -> argument("bad port #{text}")
  end
end

# The part of `text` before the first `mark`, or all of it.
def before(text: String, mark: String) -> String
  case text.index_of(mark)
    some(at) -> text.slice(0, at)
    none -> text
  end
end

# The first position of any of `marks` in `text`.
def first_of(text: String, marks: List[String]) -> Optional[Int]
  found = marks.map { |mark| text.index_of(mark) }.select { |at| at.some? }.map { |at| at.unwrap! }
  found.min
end

def found[T](value: Optional[T], text: String) -> Result[T]
  case value
    some(it) -> ok(it)
    none -> argument(text)
  end
end

def argument[T](text: String) -> Result[T] = error("http_client: #{text}", kind: "argument")

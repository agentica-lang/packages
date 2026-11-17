## The peer of the scenarios of the normal flows: the server of `std/http`, on 127.0.0.1 and a free port, which it says
## on its first line (`listening on PORT`). With the argument `tls` it serves HTTPS with `tls/server.pem`, a
## certificate for `api.test` only, signed by `tls/ca.pem` (`openssl req -x509` for the CA, then `openssl x509 -req`
## with `subjectAltName=DNS:api.test`, both for 100 years).
##
##   /hello       200 `hello`
##   /echo        200 with `METHOD TARGET [BODY]`, then the request headers whose names start with `x-` and the
##                `authorization` and `cookie` ones, as `name=value`, in the order they came, all joined by spaces
##   /status/N    status N
##   /bytes?n=N   N bytes `a`
##   /redirect/N?to=URL  status N with `Location: URL` (all that follows `to=`)
##   /loop        a 302 to itself
##   /host        200 with the `Host` header
##   /header/NAME 200 with the values of the request header NAME, joined by commas
##   /json        200 with `{"name":"ana","age":3}` as `application/json`
##   /gzip?n=N    N bytes `a`, gzipped, with `content-encoding: gzip`
##   /deflate?n=N N bytes `a` in the zlib format, with `content-encoding: deflate`
##   /bad-gzip    bytes that are not gzip, with `content-encoding: gzip`

import HTTP from "std/http"

private

def main() -> Void
  server = start(System.args().include?("tls")).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end

def start(tls: Bool) -> Result[HTTP.Server]
  return HTTP.serve("127.0.0.1", 0, HTTP.app(&answer)) if not tls

  context = try TLS.server_context(
    TLS.ServerOptions(cert_file: "fixtures/tls/server.pem", key_file: "fixtures/tls/server.key"),
  )

  HTTP.serve_tls("127.0.0.1", 0, context, HTTP.app(&answer))
end

def answer(request: HTTP.Request) -> Result[HTTP.Response]
  path = request.path
  if path == "/hello"
    return reply(200, "hello")
  elsif path == "/echo"
    return reply(200, echo(request))
  elsif path.start_with?("/status/")
    return reply(try path.split("/").last.to_i, "status")
  elsif path == "/bytes"
    return reply(200, "a" * try count(request))
  elsif path.start_with?("/redirect/")
    return moved(try path.split("/").last.to_i, request.target.split("?to=").drop(1).join("?to="))
  elsif path == "/host"
    return reply(200, HTTP.header_values(request.headers, "host").join(","))
  elsif path == "/loop"
    return moved(302, "/loop")
  elsif path.start_with?("/header/")
    return reply(200, HTTP.header_values(request.headers, path.split("/").last).join(","))
  elsif path == "/json"
    return typed(200, "application/json", "", "{\"name\":\"ana\",\"age\":3}".bytes)
  elsif path == "/gzip"
    return typed(200, "text/plain", "gzip", try Zlib.gzip(("a" * try count(request)).bytes))
  elsif path == "/deflate"
    return typed(200, "text/plain", "deflate", try Zlib.deflate(("a" * try count(request)).bytes))
  elsif path == "/bad-gzip"
    return typed(200, "text/plain", "gzip", "not gzip".bytes)
  end

  reply(404, "not found")
end

def echo(request: HTTP.Request) -> String
  body = String.from_bytes(request.body).unwrap_or("")
  marked = request.headers
    .select { |header| header.name.start_with?("x-") or ["authorization", "cookie"].include?(header.name) }
    .map { |header| "#{header.name}=#{header.value}" }

  (["#{request.method} #{request.target} [#{body}]"] + marked).join(" ")
end

def count(request: HTTP.Request) -> Result[Int] = request.target.split("n=").last.to_i

def typed(status: Int, type: String, encoding: String, body: Bytes) -> Result[HTTP.Response]
  headers = [HTTP.Header(name: "content-type", value: type)]
  if not encoding.empty?
    headers = headers.push(HTTP.Header(name: "content-encoding", value: encoding))
  end

  ok(HTTP.Response(status: status, headers: headers, body: body))
end

def reply(status: Int, text: String) -> Result[HTTP.Response]
  ok(HTTP.Response(status: status, headers: [], body: text.bytes))
end

def moved(status: Int, location: String) -> Result[HTTP.Response]
  ok(HTTP.Response(status: status, headers: [HTTP.Header(name: "location", value: location)], body: "moved".bytes))
end

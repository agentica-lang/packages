## The peer of the scenarios of the normal flows: the server of `std/http`, on 127.0.0.1 and a free port, which it says
## on its first line (`listening on PORT`).
##
##   /hello       200 `hello`
##   /echo        200 with `METHOD TARGET [BODY]`, then the request headers whose names start with `x-` and the
##                `authorization` and `cookie` ones, as `name=value`, in the order they came, all joined by spaces
##   /status/N    status N
##   /bytes?n=N   N bytes `a`
##   /redirect/N?to=URL  status N with `Location: URL` (all that follows `to=`)
##   /loop        a 302 to itself

import HTTP from "std/http"

private

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&answer)).unwrap!
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
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
    return reply(200, "a" * try request.target.split("n=").last.to_i)
  elsif path.start_with?("/redirect/")
    return moved(try path.split("/").last.to_i, request.target.split("?to=").drop(1).join("?to="))
  elsif path == "/loop"
    return moved(302, "/loop")
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

def reply(status: Int, text: String) -> Result[HTTP.Response]
  ok(HTTP.Response(status: status, headers: [], body: text.bytes))
end

def moved(status: Int, location: String) -> Result[HTTP.Response]
  ok(HTTP.Response(status: status, headers: [HTTP.Header(name: "location", value: location)], body: "moved".bytes))
end

## The peer of the scenarios that need a real WebSocket server: the one of `std/http`, on 127.0.0.1 and a free port,
## which it says on its first line. With the environment variables `TLS_CERT` and `TLS_KEY` (PEM files) it serves
## `wss`.
##
## `/echo` sends every text and binary message back. `/headers` sends one text at once with the `Cookie` and
## `Authorization` of the handshake. `/chat` accepts the subprotocols `chat` and `other` and says which it chose.

import HTTP from "std/http"

private

PROTOCOLS = ["chat", "other"]

def echo(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(60_000)
      error(_) -> return ok()
      ok(message) ->
        case message
          HTTP.Message.Text(text) -> try ws.outgoing.send(HTTP.Message.Text(text), 5_000)
          HTTP.Message.Binary(data) -> try ws.outgoing.send(HTTP.Message.Binary(data), 5_000)
          HTTP.Message.Close(_, _) -> return ok()
          HTTP.Message.Ping(_) -> nil
          HTTP.Message.Pong(_) -> nil
          HTTP.Message.Prepared(_) -> nil
        end
    end
  end

  ok()
end

def header_of(request: HTTP.Request, name: String) -> String
  values = HTTP.header_values(request.headers, name)
  return "none" if values.empty?

  values[0]
end

def say_headers(request: HTTP.Request, ws: HTTP.WebSocket) -> Result[Void]
  text = "cookie=#{header_of(request, "cookie")};authorization=#{header_of(request, "authorization")}"
  try ws.outgoing.send(HTTP.Message.Text(text), 5_000)
  echo(ws)
end

def say_protocol(ws: HTTP.WebSocket) -> Result[Void]
  try ws.outgoing.send(HTTP.Message.Text("protocol=#{ws.protocol}"), 5_000)
  echo(ws)
end

def session(f: Fn[HTTP.WebSocket, Result[Void]]) -> Fn[HTTP.WebSocket, Result[Void]] = f

def route(request: HTTP.Request, _body: HTTP.RequestBody) -> Result[HTTP.Answer]
  options = HTTP.WebSocketOptions(protocols: PROTOCOLS)
  case request.path
    "/echo" -> ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &echo, options)))
    "/headers" ->
      ok(
        HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, session do |ws| say_headers(request, ws) end, options)),
      )
    "/chat" -> ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &say_protocol, options)))
    _ -> ok(HTTP.Answer.Whole(HTTP.Response(status: 404, headers: [], body: "not found".bytes)))
  end
end

def start() -> HTTP.Server
  cert = System.env("TLS_CERT")
  key = System.env("TLS_KEY")
  if cert.ok? and key.ok?
    context = TLS.server_context(TLS.ServerOptions(cert_file: cert.unwrap!, key_file: key.unwrap!)).unwrap!
    return HTTP.serve_tls("127.0.0.1", 0, context, &route).unwrap!
  end

  HTTP.serve("127.0.0.1", 0, &route).unwrap!
end

def main() -> Void
  server = start()
  puts("listening on #{HTTP.local_port(server)}")
  IO.flush()
  HTTP.wait(server).unwrap!
end

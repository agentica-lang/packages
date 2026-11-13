---
title: websocket-client
description: A WebSocket client (RFC 6455) over std TCP and TLS. Connect to ws:// and wss://, send and receive text and binary messages, and close cleanly.
---

`websocket-client` opens a WebSocket from an Agentica program. It does the HTTP/1.1 upgrade, checks the answer of the server, masks every frame it sends, joins fragments, answers pings, and runs the close handshake. A server that breaks the rules gets a close frame with the right code, and the caller gets an `error`, never a crash.

Use it to talk to any WebSocket server, or to test the one of your own app from Agentica tests with no peer in another language.

## Install

Needs Agentica 0.31.0 or later. Add it in a project with an `agentica.toml`:

```sh
agentica add websocket-client https://github.com/agentica-lang/packages --tag websocket-client-0.3.0 --subdir websocket-client
```

That writes this line of `agentica.toml`, and the entry of `agentica.lock`:

```toml
[dependencies]
websocket-client = { git = "https://github.com/agentica-lang/packages", tag = "websocket-client-0.3.0", subdir = "websocket-client" }
```

The releases and their notes are in the [changelog](https://github.com/agentica-lang/packages/blob/main/websocket-client/CHANGELOG.md).

## Example

A server of `std/http` that answers in capitals, and a client that talks to it:

```agentica
import WebSocket from "pkg/websocket-client/websocket"
import HTTP from "std/http"

def shout(ws: HTTP.WebSocket) -> Result[Void]
  while true
    case ws.incoming.recv(5000)
      ok(HTTP.Message.Text(text)) -> try ws.outgoing.send(HTTP.Message.Text(text.upcase), 5000)
      ok(HTTP.Message.Close(_, _)) -> return ok()
      ok(_) -> nil
      error(_) -> return ok()
    end
  end

  ok()
end

def route(request: HTTP.Request, _body: HTTP.RequestBody) -> Result[HTTP.Answer]
  ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &shout)))
end

def talk(url: String) -> Result[Void]
  ws = try WebSocket.connect(url)
  try WebSocket.send_text(ws, "hello")
  case try WebSocket.receive(ws)
    WebSocket.Message.Text(text) -> puts(text)
    WebSocket.Message.Binary(data) -> puts("#{data.size} bytes")
    WebSocket.Message.Close(code, reason) -> puts("closed #{code} #{reason}")
  end

  WebSocket.close(ws)
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &route).unwrap!
  talk("ws://127.0.0.1:#{HTTP.local_port(server)}/").unwrap!
  HTTP.close_server(server)
end
```

```output
HELLO
```

## API

The functions are in `pkg/websocket-client/websocket`. A `Client` is what `connect` returns, and the functions take it first.

```text
WebSocket.connect(url: String, options: WebSocket.Options = WebSocket.Options()) -> Result[WebSocket.Client]
WebSocket.handshake(url: String, options: WebSocket.Options = WebSocket.Options()) -> Result[WebSocket.Handshake]
WebSocket.send_text(client, text: String) -> Result[Void]
WebSocket.send_binary(client, data: Bytes) -> Result[Void]
WebSocket.send_ping(client, data: Bytes) -> Result[Void]
WebSocket.send_pong(client, data: Bytes) -> Result[Void]
WebSocket.receive(client) -> Result[WebSocket.Message]
WebSocket.close(client, code: Int = 1000, reason: String = "") -> Result[Void]

WebSocket.Message: Text(String), Binary(Bytes), Close(Int, String)
WebSocket.Handshake: Open(WebSocket.Client), Refused(status: Int, headers: List[HTTP.Header], body: String)
WebSocket.Client(socket, protocol: String, options, status: Int, headers: List[HTTP.Header])
WebSocket.Options(headers: List[HTTP.Header] = [], protocols: List[String] = [], max_message_bytes: Int = 1048576,
                  timeout_ms: Int = 30000, read_timeout_ms: Int = 30000, close_timeout_ms: Int = 5000,
                  tls: Optional[TLS.Context] = none)
```

[How it behaves](behavior.md) has what `receive` does with each frame, the limits, the errors, headers, subprotocols, `wss` and the use from several tasks.

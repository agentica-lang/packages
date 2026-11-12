---
title: Behavior
description: What connect, receive, send and close do, the limits, the errors, headers, subprotocols, wss and tasks.
weight: 1
---

## Connect

`WebSocket.connect(url)` takes a `ws://` or `wss://` URL. The port defaults to 80 or 443 and the path to `/`. The fragment is dropped, and user info (`ws://user:pass@host`) is refused: send credentials in a header. An IPv6 host goes in brackets.

It opens a TCP connection (TLS for `wss`), sends the upgrade request with a new random `Sec-WebSocket-Key`, and checks the answer. The handshake is refused, and the socket closed, for a status other than 101, a missing `Upgrade: websocket` or `Connection: Upgrade`, a wrong `Sec-WebSocket-Accept`, a subprotocol that the client did not offer, and an extension (the client offers none).

`Options.headers` go in the request: cookies, `Authorization`, `Origin`. `Host`, `Upgrade`, `Connection` and the `Sec-WebSocket-*` headers are written by the handshake and refused here, as is a name that is not a token or a value with a line break.

`Options.protocols` lists the subprotocols to offer, and `client.protocol` is the one the server chose (`""` for none):

```agentica {mode="check"}
import WebSocket from "pkg/websocket-client/websocket"

def connect_to_cable() -> Result[WebSocket.Client]
  options = WebSocket.Options(
    protocols: ["actioncable-v1-json"],
    headers: [Header(name: "Cookie", value: "user=ana"), Header(name: "Origin", value: "http://127.0.0.1:3000")],
  )
  WebSocket.connect("ws://127.0.0.1:3000/cable", options)
end
```

For `wss`, the system trust is used. To trust another certificate, build a context and pass it as `tls`:

```agentica {mode="check"}
import WebSocket from "pkg/websocket-client/websocket"

def connect_with_ca() -> Result[WebSocket.Client]
  context = try TLS.client_context(TlsClientOptions(ca_file: "ca.pem"))
  WebSocket.connect("wss://localhost:8443/", WebSocket.Options(tls: some(context)))
end
```

## Send

`send_text`, `send_binary`, `send_ping` and `send_pong` write one whole frame, always masked with a new random key. A ping or a pong carries at most 125 bytes. A message is at most 1 MiB less its frame head, because a frame goes out in one write, so that tasks that send at once never mix their frames; a larger payload is an `error` before anything is sent. A send that times out (`timeout_ms`) closes the socket.

Masking runs in Agentica, at about 2 MB/s.

## Receive

`receive` waits for the next message and returns it whole:

- Fragments of a message are joined, and a control frame between them is handled on the way.
- A ping is answered at once with a pong that has the same payload. A pong is dropped.
- A text message is checked to be UTF-8.
- A close frame is answered with its code, the socket is closed, and `receive` returns `Close(code, reason)`. The code is 1005 when the server sent none. A connection that ends with no close frame (the server dropped it, even in the middle of a frame, or reset it) is `Close(1006, "")`, as the server of `std/http` tells its sessions.
- After a `Close`, or after `close`, the next `receive` is an `error`.

These make `receive` close the connection with a close frame and return an `error` with the rule that was broken:

| What the server sent | Close code |
|---|---|
| a masked frame, a reserved bit (no extension is in use), an unknown opcode, a control frame over 125 bytes or fragmented, a continuation with no message, a new message inside a fragmented one, a length that is not in its shortest form, a bad close frame (one byte, or a code that no peer may send) | 1002 |
| a text message that is not UTF-8, or a close reason that is not | 1007 |
| a message over `max_message_bytes` (all its fragments together) | 1009 |

The size is checked from the head of a frame, before its payload is read, so a server cannot make the client hold more than `max_message_bytes`.

`read_timeout_ms` is the time for one whole frame, from the first byte to the last, so a server that sends a byte now and then cannot hold `receive`. A frame that is not complete by then is an `error` and the connection is closed. A server that pings keeps the connection alive, since each frame that arrives starts a new wait. The handshake and the wait of `close` have their own deadline the same way. For a quiet server, use a long `read_timeout_ms`.

## Close

`WebSocket.close(ws, 1000, "done")` sends a close frame, waits up to `close_timeout_ms` for the answer, drops the data that arrives meanwhile, and closes the socket. It returns `ok` also when the connection was already closed. The code is 1000 to 1003, 1007 to 1014, or 3000 to 4999, and the reason is at most 123 bytes: another one is an `error` and nothing is sent.

A socket also closes when the task that connected ends, so connect in the task that keeps the connection.

## Tasks

The functions can be called from any task, and a send and a receive can run at the same time. To read in the background, give the connection to a task that puts the messages in a channel. The task that connected must live as long as the connection:

```agentica
import WebSocket from "pkg/websocket-client/websocket"
import HTTP from "std/http"

struct Line
  ws: WebSocket.Client
  inbox: Channel[WebSocket.Message]
end

def count_up(ws: HTTP.WebSocket) -> Result[Void]
  for n in 1..3
    try ws.outgoing.send(HTTP.Message.Text("tick #{n}"), 5000)
  end

  ws.outgoing.send(HTTP.Message.Close(1000, "enough"), 5000)
end

def route(request: HttpRequest, _body: HTTP.RequestBody) -> Result[HTTP.Answer]
  ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &count_up)))
end

# The task that reads: it puts every message in the channel, and ends with the close.
def pump(line: Line) -> Void
  while true
    case WebSocket.receive(line.ws)
      ok(message) ->
        _ = line.inbox.send(message, 5000)
        case message
          WebSocket.Message.Close(_, _) -> break
          WebSocket.Message.Text(_) -> nil
          WebSocket.Message.Binary(_) -> nil
        end

      error(_) -> break
    end
  end

  line.inbox.close
end

def main() -> Void
  server = HTTP.serve("127.0.0.1", 0, &route).unwrap!
  ws = WebSocket.connect("ws://127.0.0.1:#{HTTP.local_port(server)}/").unwrap!
  inbox: Channel[WebSocket.Message] = Channel.new(8)
  reader = Task.spawn(&pump, Line(ws: ws, inbox: inbox))
  while true
    case inbox.recv(5000)
      error(_) -> break
      ok(message) ->
        case message
          WebSocket.Message.Text(text) -> puts(text)
          WebSocket.Message.Binary(_) -> nil
          WebSocket.Message.Close(code, reason) -> puts("closed #{code} #{reason}")
        end
    end
  end

  Task.await(reader)
  HTTP.close_server(server)
end
```

```output
tick 1
tick 2
tick 3
closed 1000 enough
```

## Not in this version

- permessage-deflate (compression): the client offers no extension, and refuses a server that chooses one.
- A message over 1 MiB to send, which would need to be fragmented.
- Redirects, proxies, and an automatic reconnect.
- A built-in receive task and channel.

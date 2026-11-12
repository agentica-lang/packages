## A WebSocket client (RFC 6455) over `std` TCP and TLS.
##
## ```ruby
## import WebSocket from "pkg/websocket-client/websocket"
##
## ws = WebSocket.connect("ws://127.0.0.1:3000/cable", WebSocket.Options(protocols: ["actioncable-v1-json"])).unwrap!
## WebSocket.send_text(ws, "hello").unwrap!
## case WebSocket.receive(ws).unwrap!
##   WebSocket.Message.Text(text) -> puts(text)
##   WebSocket.Message.Binary(data) -> puts(data.size)
##   WebSocket.Message.Close(code, reason) -> puts("closed #{code} #{reason}")
## end
## WebSocket.close(ws).unwrap!
## ```
##
## Every frame that the client writes is masked. `receive` joins the fragments of a message, answers a ping with a
## pong, drops a pong, and answers a close frame with its code before it returns the `Close`. A frame that breaks the
## protocol makes `receive` close the connection with the right code and return an `error`; none of this crashes.

import Connection from "src/connection"
import Frame from "src/frame"
import Types from "src/types"

export Types.Client
export Types.Handshake
export Types.Message
export Types.Options

## Connects to a `ws://` or `wss://` URL and returns the `Client` (its `status` and `headers` are the answer of the
## server): the TCP or TLS connection, then the HTTP/1.1 upgrade of RFC 6455. An `error` for a bad URL or option, a
## failed connect, an answer that is not a good handshake (a status other than 101, a wrong `Sec-WebSocket-Accept`, a
## subprotocol that was not offered, an extension), and a timeout. It stops at the head of a refusing answer, and does
## not read its body (`handshake` does).
export def connect(url: String, options: Types.Options = Types.Options()) -> Result[Types.Client]
  Connection.connect(url, options)
end

## Like `connect`, but a server that answers with a status from 200 to 599 other than 101 is not an `error`: the result
## is `Refused` with the status, the headers (names as the server wrote them, the first `Content-Length` counts) and the
## start of the body. The body is at most 64 KiB, as long as that `Content-Length` says; the bytes that came before the
## peer closed or `timeout_ms` ended are kept; "" when there is no `Content-Length` or it is not a number; one that
## does not fit an Int counts as the cap. A body cut in the middle of a character loses that character, and bytes that
## are still not UTF-8 give "". The socket is closed then. `timeout_ms` covers the request, the head and the body
## together, after the connect. An `error` is a bad URL or option, a failed connect, a timeout, an answer that is not
## HTTP, a status outside 200 to 599 (a 1xx is not skipped), and a 101 that is not a good handshake (wrong accept, no
## `Upgrade`, a subprotocol that was not offered, an extension).
export def handshake(url: String, options: Types.Options = Types.Options()) -> Result[Types.Handshake]
  Connection.handshake(url, options)
end

## Sends a text message (one frame). A message over 1 MiB less its head is an `error`.
export def send_text(client: Types.Client, text: String) -> Result[Void]
  Connection.send_data(client, Frame.TEXT, text.bytes)
end

## Sends a binary message (one frame). A message over 1 MiB less its head is an `error`.
export def send_binary(client: Types.Client, data: Bytes) -> Result[Void]
  Connection.send_data(client, Frame.BINARY, data)
end

## Sends a ping with a payload (empty is fine); the server answers it with a pong. At most 125 bytes.
export def send_ping(client: Types.Client, data: Bytes) -> Result[Void]
  Connection.send_control(client, Frame.PING, data)
end

## Sends a pong that nobody asked for, a one-way heartbeat. The payload is at most 125 bytes.
export def send_pong(client: Types.Client, data: Bytes) -> Result[Void]
  Connection.send_control(client, Frame.PONG, data)
end

## Waits for the next text or binary message, whole. A `Close` ends the connection, and the next `receive` is an
## `error`. An `error` is also a frame that breaks the protocol (the connection is closed with the code that the rule
## names), a message over `max_message_bytes`, text that is not UTF-8, and a server that stays silent for
## `read_timeout_ms` (which closes the connection).
export def receive(client: Types.Client) -> Result[Types.Message] = Connection.receive(client)

## The close handshake: sends a close frame with the code (1000, or 3000 to 4999, and so on) and a reason of at most
## 123 bytes, waits up to `close_timeout_ms` for the answer of the server, and closes the socket. It is `ok` also
## when the connection was already closed. An `error` only for a code or reason that cannot be sent.
export def close(client: Types.Client, code: Int = 1000, reason: String = "") -> Result[Void]
  Connection.close(client, code, reason)
end

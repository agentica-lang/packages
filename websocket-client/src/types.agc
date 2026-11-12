## The records of the package.

## What `connect` takes besides the URL. The timeouts are in milliseconds and positive.
##
## `headers` go in the handshake (cookies, `Authorization`, `Origin`); the headers that the handshake writes itself are
## refused. `protocols` are the subprotocols offered, in order of preference. `max_message_bytes` caps a message, all
## its fragments together. `timeout_ms` covers the connect, the handshake and each send. `read_timeout_ms` is how long
## `receive` waits for the next bytes of the server: a read that times out ends the connection. `close_timeout_ms` is
## how long `close` waits for the answer of the server. `tls` is the client context of a `wss://` URL (the system
## trust by default).
export struct Options
  headers: List[Header] = []
  protocols: List[String] = []
  max_message_bytes: Int = 1_048_576
  timeout_ms: Int = 30_000
  read_timeout_ms: Int = 30_000
  close_timeout_ms: Int = 5_000
  tls: Optional[TlsContext] = none
end

## A message that `receive` returns. A `Close` has the code and the reason of the server: 1005 when it sent none, and
## 1006 when the connection ended with no close frame.
export enum Message
  Text(String)
  Binary(Bytes)
  Close(Int, String)
end

## An open connection. `protocol` is the subprotocol that the server chose ("" for none).
export struct Client
  socket: Socket
  protocol: String
  options: Options
end

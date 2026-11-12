## The records of the package.

## The most that a timeout may be, in milliseconds: one day.
export MAX_TIMEOUT_MS = 86_400_000

## The most that the body of a refused answer keeps, in bytes.
export MAX_BODY_BYTES = 65_536

## What `connect` takes besides the URL. The timeouts are in milliseconds, from 1 to `MAX_TIMEOUT_MS`: a larger one is
## an `error`.
##
## `headers` go in the handshake (cookies, `Authorization`, `Origin`); the headers that the handshake writes itself are
## refused. `protocols` are the subprotocols offered, in order of preference. `max_message_bytes` caps a message, all
## its fragments together. `timeout_ms` covers the connect, the whole handshake and each send. `read_timeout_ms` is how
## long `receive` takes to read one whole frame: one that is not complete by then ends the connection.
## `close_timeout_ms` is how long `close` waits for the answer of the server. `tls` is the client context of a
## `wss://` URL (the system trust by default).
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

## An open connection. `protocol` is the subprotocol that the server chose ("" for none). `status` and `headers` are
## the answer of the 101 handshake, with the names of the headers as the server wrote them.
export struct Client
  socket: Socket
  protocol: String
  options: Options
  status: Int = 101
  headers: List[Header] = []
end

## What `handshake` returns: the open connection, or the answer of a server that did not upgrade (any status but 101),
## with its headers and the start of its body (`MAX_BODY_BYTES` at most; empty when it sent no `Content-Length`).
export enum Handshake
  Open(Client)
  Refused(Int, List[Header], String)
end

## What runs in the task of one client.

import {Conn} from "types"

# TCP.send_bytes takes at most 1 MiB.
SEND_PIECE = 1_048_576

export struct Link
  conn: Conn
  handler: Fn[Conn, Void]
end

## Runs the handler, then closes the socket. A crash or a cancel skips the close: the supervisor closes it when
## the monitor tells it the task ended (the socket is owned by the supervisor, see server.agc).
export def run(link: Link) -> Void
  link.handler(link.conn)
  TCP.close(link.conn.socket)
end

export def recv(conn: Conn, max_bytes: Int) -> Result[Bytes]
  return TCP.recv_bytes(conn.socket, max_bytes, conn.idle_ms)
end

export def send(conn: Conn, bytes: Bytes) -> Result[Void]
  rest = bytes
  while not rest.empty?
    try TCP.send_bytes(conn.socket, rest.take(SEND_PIECE), conn.send_ms)
    rest = rest.drop(SEND_PIECE)
  end

  return ok()
end

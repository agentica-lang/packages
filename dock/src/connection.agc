## What runs in the task of one client, and what the handler calls.

import {ClientParts, Conn} from "types"

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
  close(link.conn)
end

export def close(conn: Conn) -> Void
  case conn.inside
    ClientParts.Parts(socket, _, _) -> TCP.close(socket)
  end
end

export def recv(conn: Conn, max_bytes: Int = 65_536) -> Result[Bytes]
  case conn.inside
    ClientParts.Parts(socket, idle_ms, _) -> return TCP.recv_bytes(socket, max_bytes, idle_ms)
  end
end

export def send(conn: Conn, bytes: Bytes) -> Result[Void]
  case conn.inside
    ClientParts.Parts(socket, _, send_ms) ->
      rest = bytes
      while not rest.empty?
        try TCP.send_bytes(socket, rest.take(SEND_PIECE), send_ms)
        rest = rest.drop(SEND_PIECE)
      end

      return ok()
  end
end

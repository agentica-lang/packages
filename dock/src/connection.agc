## What runs in the task of one client, and what the handler calls.

import Outbox from "outbox"
import {ClientParts, Conn} from "types"

# How long the queued bytes get to be written after the handler returned or called `close`.
DRAIN_MS = 30_000

export struct Link
  conn: Conn
  handler: Fn[Conn, Void]
end

## Starts the writer, runs the handler, then lets the writer finish what is queued and closes the socket. A crash or
## a cancel skips that: the writer is a task of this one, so it ends with it, and the supervisor closes the socket
## when the monitor tells it the task ended (the socket is owned by the supervisor, see server.agc).
export def run(link: Link) -> Void
  case link.conn.inside
    ClientParts.Parts(socket, _, outbox) ->
      writer = Task.spawn(&Outbox.run, Outbox.Pipe(socket: socket, outbox: outbox))
      link.handler(link.conn)
      Outbox.finish(outbox, socket)
      case Task.await(writer, DRAIN_MS)
        Await.Done(_) -> nil
        Await.TimedOut -> Task.cancel(writer)
      end

      TCP.close(socket)
  end
end

export def close(conn: Conn) -> Void
  case conn.inside
    ClientParts.Parts(socket, _, outbox) -> Outbox.finish(outbox, socket)
  end
end

export def recv(conn: Conn, max_bytes: Int = 65_536) -> Result[Bytes]
  case conn.inside
    ClientParts.Parts(socket, idle_ms, _) -> return TCP.recv_bytes(socket, max_bytes, idle_ms)
  end
end

export def send(conn: Conn, bytes: Bytes) -> Result[Void]
  case conn.inside
    ClientParts.Parts(socket, _, outbox) -> return Outbox.push(outbox, socket, bytes)
  end
end

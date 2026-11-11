## What runs in the task of one client, and what the handler calls.

import Outbox from "outbox"
import {ClientParts, Conn} from "types"

# How long the queued bytes get to be written after the handler returned or called `close`.
DRAIN_MS = 30_000

# TCP.recv_bytes takes at most 1 MiB.
MAX_RECV = 1_048_576

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
      if Outbox.handed_over?(outbox)
        # Another task owns the connection now. The writer ends at `close`, a drop, a failed send or a read that saw
        # the end; a cancel (the stop) ends this task and the writer with it.
        Task.await(writer)
      else
        Outbox.finish(outbox, socket)
        case Task.await(writer, DRAIN_MS)
          Await.Done(_) -> nil
          Await.TimedOut -> Task.cancel(writer)
        end
      end

      TCP.close(socket)
  end
end

export def close(conn: Conn) -> Void
  case conn.inside
    ClientParts.Parts(socket, _, outbox) -> Outbox.finish(outbox, socket)
  end
end

## Tells dock that another task owns the connection, so the handler may return without closing it. Call it in the
## handler, before the connection is given away and before returning.
export def hand_over(conn: Conn) -> Void
  case conn.inside
    ClientParts.Parts(_, _, outbox) -> Outbox.hand_over(outbox)
  end
end

## After a hand-over, nobody reads the socket unless a task calls `recv`: a `recv` that gets the end of the client (empty
## bytes) or fails (the idle time passed, say) then closes the connection as `close` does, since no handler is left to.
export def recv(conn: Conn, max_bytes: Int = 65_536) -> Result[Bytes]
  case conn.inside
    ClientParts.Parts(socket, idle_ms, outbox) ->
      # A bad argument is the caller's mistake, not the end of the client: it must not close a handed over connection.
      if max_bytes < 1 or max_bytes > MAX_RECV
        return error("dock: max_bytes must be 1 to #{MAX_RECV}, got #{max_bytes}")
      end

      got = TCP.recv_bytes(socket, max_bytes, idle_ms)
      if Outbox.handed_over?(outbox)
        case got
          ok(chunk) ->
            if chunk.empty?
              Outbox.finish(outbox, socket)
            end

          error(_) -> Outbox.finish(outbox, socket)
        end
      end

      got
  end
end

export def send(conn: Conn, bytes: Bytes) -> Result[Void]
  case conn.inside
    ClientParts.Parts(socket, _, outbox) -> Outbox.push(outbox, socket, bytes)
  end
end

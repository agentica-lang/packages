## The records of the public API.

import {Outbox} from "outbox"

export struct Config
  ## The port to listen on; 0 picks a free one, and `Server.port` says which.
  port: Int
  host: String = "127.0.0.1"
  ## How long `Dock.recv` waits for bytes. A receive that times out closes the socket and there is no wait-forever
  ## form, so the default is one year.
  idle_ms: Int = 31_536_000_000
  ## The bytes that may wait in the outbox of a client, 64 more for each message. A client that does not read is
  ## dropped when more than this waits: 65 to 68,157,310.
  max_outbox_bytes: Int = 8_388_608
  ## The most connections open at once, 1 to 1,048,576. One that comes when that many are open is accepted and closed
  ## at once (the accept loop never waits), and counted as `refused`.
  max_connections: Int = 65_536
  ## How long `stop` lets the queued bytes of the clients be written before it closes their sockets: each client is
  ## closed as `Dock.close` does, and one that is still there after this long is cancelled. 0 closes at once.
  grace_ms: Int = 0
  ## `none` does nothing (a struct field cannot default to a function). Runs once for each connection that ended (the handler returned, crashed or was cancelled by `stop`), in a task of
  ## its own after the socket is closed, so a slow callback never holds the accept loop. It is where a state task
  ## learns that a client is gone (send `conn.id` to it).
  on_close: Optional[Fn[Conn, Void]] = none
end

# The fields of Conn and Server that the user must not touch. They sit in an enum that dock.agc does not re-export:
# a user can hold the value but cannot name its type, so a `case` on it does not check, and a struct has no way to
# hide a field otherwise (a private struct can still be read through the field). Private fields are asked for in
# agentica-lang/agentica#1344; the enums go when they land.
export enum ClientParts
  # The socket, `idle_ms` and the outbox.
  Parts(Socket, Int, Outbox)
end

export enum ServerParts
  # The channel that is closed to stop the server, the supervisor task, the counters, the channel where `watch` sends
  # the end of a task, and `grace_ms`.
  Parts(Channel[Bool], Task[Result[Void]], ATS[Int, Int], Channel[String], Int)
end

## One client, given to the handler; do not build one. Talk to it with `Dock.send`, `Dock.recv` and `Dock.close`;
## `inside` is private.
export struct Conn
  id: Int
  ## The IP of the client, without the port.
  peer: String
  inside: ClientParts
end

## A running server, given by `Dock.start`. `inside` is private.
export struct Server
  port: Int
  inside: ServerParts
end

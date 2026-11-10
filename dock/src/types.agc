## The records of the public API.

export struct Config
  ## The port to listen on; 0 picks a free one, and `Server.port` says which.
  port: Int
  host: String = "127.0.0.1"
  ## How long `Dock.recv` waits for bytes. A receive that times out closes the socket and there is no wait-forever
  ## form, so the default is one year.
  idle_ms: Int = 31_536_000_000
  ## How long `Dock.send` waits for the client to take each piece of 1 MiB; a send that times out closes the socket.
  ## It goes away when `send` is queued.
  send_ms: Int = 5000
end

# The fields of Conn and Server that the user must not touch. They sit in an enum that dock.agc does not re-export:
# a user can hold the value but cannot name its type, so a `case` on it does not check, and a struct has no way to
# hide a field otherwise (a private struct can still be read through the field).
export enum ClientParts
  # The socket, `idle_ms` and `send_ms`.
  Parts(Socket, Int, Int)
end

export enum ServerParts
  # The channel that is closed to stop the server, and the supervisor task.
  Parts(Channel[Bool], Task[Result[Void]])
end

## One client, given to the handler. Talk to it with `Dock.send`, `Dock.recv` and `Dock.close`; `inside` is private.
export struct Conn
  id: Int
  ## The IP of the client, without the port.
  peer: String
  inside: ClientParts
end

## A running server. `inside` is private.
export struct Server
  port: Int
  inside: ServerParts
end

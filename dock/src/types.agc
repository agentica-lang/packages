## The records of the public API.

export struct Config
  ## The port to listen on; 0 picks a free one, and `Server.port` says which.
  port: Int
  host: String = "127.0.0.1"
  ## How long `Dock.recv` waits for bytes. A receive that times out closes the socket and there is no wait-forever
  ## form, so the default is one year.
  idle_ms: Int = 31_536_000_000
  ## How long `Dock.send` waits for the client to take each piece of 1 MiB.
  send_ms: Int = 5000
end

## One client, given to the handler.
export struct Conn
  id: Int
  socket: Socket
  ## The IP of the client, without the port.
  peer: String
  idle_ms: Int
  send_ms: Int
end

## A running server.
export struct Server
  port: Int
  stop_signal: Channel[Bool]
  task: Task[Result[Void]]
end

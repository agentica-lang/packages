---
title: dock
description: A TCP server. An accept loop, one task per client that runs your handler, and the clean-up when a client ends or crashes.
---

`dock` is the part every TCP server writes again. It listens, accepts, runs your handler in a task of its own for each client, and closes the socket when the handler returns, crashes or is stopped. The server never waits for one client. It does not parse a protocol, and it does not do HTTP (that is `std/http`).

```agentica
import Dock from "pkg/dock/dock"

def echo(conn: Dock.Conn) -> Void
  while true
    case Dock.recv(conn, 4096)
      error(_) -> return
      ok(chunk) ->
        if chunk.empty?
          return
        end

        case Dock.send(conn, chunk)
          error(_) -> return
          ok(_) -> nil
        end
    end
  end
end

def main() -> Void
  server = Dock.start(Dock.Config(port: 0), &echo).unwrap!
  client = TCP.connect("127.0.0.1", server.port, 1000).unwrap!
  TCP.send(client, "hello", 1000).unwrap!
  puts(String.from_bytes(TCP.recv_bytes(client, 16, 1000).unwrap!).unwrap!)
  TCP.close(client)
  Dock.stop(server).unwrap!
end
```

```output
hello
```

Port 0 picks a free port, and `server.port` is the real one: `start` returns once the port is open, so there is no ready callback to wait for.

## API

```signature
Dock.start(config: Config, handler: Fn[Conn, Void]) -> Result[Server]
Dock.stop(server: Server) -> Result[Void]
Dock.wait(server: Server) -> Result[Void]
Dock.recv(conn: Conn, max_bytes: Int = 65536) -> Result[Bytes]
Dock.send(conn: Conn, bytes: Bytes) -> Result[Void]

Config(port: Int, host: String = "127.0.0.1", idle_ms: Int = 31536000000, send_ms: Int = 5000)
Conn(id: Int, socket: Socket, peer: String, idle_ms: Int, send_ms: Int)
Server(port: Int, ...)
```

- `start` listens and returns the `Server`, or the error of the listen (a port in use, say). The handler runs once for each client, in its own task, and gets a `Conn`. When it returns, the socket is closed.
- `stop` stops accepting, cancels the handlers, closes every socket and frees the port. It returns after that, or an error if the server crashed. `wait` blocks until the server ends: a program that only serves ends `main` with it.
- `recv` and `send` are `TCP.recv_bytes` and `TCP.send_bytes` with the timeouts of the `Config`. `recv` gives empty bytes when the client closed. `send` cuts `bytes` into the pieces that `TCP.send_bytes` takes, so it has no size limit.
- A handler is a function, or a block that captures what it needs. A server with one task that owns the state passes it a channel:

```agentica {mode="check"}
import Dock from "pkg/dock/dock"

enum Msg
  Line(Bytes)
end

def serve(conn: Dock.Conn, inbox: Channel[Msg]) -> Void
  case Dock.recv(conn, 4096)
    error(_) -> return
    ok(chunk) -> _ = inbox.send(Msg.Line(chunk), 1000)
  end
end

def main() -> Void
  inbox: Channel[Msg] = Channel.new(1024)
  server = Dock.start(Dock.Config(port: 6380)) do |conn| serve(conn, inbox) end.unwrap!
  Dock.wait(server).unwrap!
end
```

## Why it is built this way

- One task per client, started by a supervisor task that owns the listener. The supervisor never calls anything that waits for a client: it only accepts (100 ms at most), starts tasks and closes sockets.
- The supervisor owns the sockets, not the client tasks, so that it can close one when its handler crashed or was cancelled (a crash does not run the handler's last lines). It learns of the end of every task with `Task.monitor`. The task closes the socket itself when the handler returns, so the client sees the end at once. A close is idempotent, so the second one does nothing. A lost notice would keep a socket until the server stops, so the channel of notices holds a million, the most sockets a process can have, and a full channel is the only way to lose one.
- `Task.spawn_owning` would give the socket to the task, but it cannot also pass a shared channel ([agentica#1341](https://github.com/agentica-lang/agentica/issues/1341)), which a handler that talks to a state task needs.
- A receive that times out closes the socket, and there is no wait-forever form ([agentica#1342](https://github.com/agentica-lang/agentica/issues/1342)). So `idle_ms` is a value of the `Config`, one year by default.
- An accept that fails at once (no free file descriptor) waits the rest of the 100 ms before the next try, so it cannot spin.

## Planned

Tracked in [#71](https://github.com/agentica-lang/packages/issues/71): a writer side (an outbox for each client with a limit in bytes, so a client that does not read is dropped and nobody waits), pushes to a client from another task, a limit of connections, counters (open, accepted, dropped), a graceful stop, and stopping when the task of the user dies.

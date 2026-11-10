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
Dock.close(conn: Conn) -> Void

Config(port: Int, host: String = "127.0.0.1", idle_ms: Int = 31536000000, send_ms: Int = 5000)
Conn(id: Int, peer: String)
Server(port: Int)
```

- `start` listens and returns the `Server`, or the error of the listen (a port in use, say). The handler runs once for each client, in its own task, and gets a `Conn`. When it returns, the socket is closed.
- `stop` stops accepting, cancels the handlers, closes every socket and frees the port. It returns after that, or an error if the server crashed, and a second call gives the same result. `wait` blocks until the server ends: a program that only serves ends `main` with it. If the listener is closed under the loop, the server ends with an error that `wait` and `stop` return.
- `recv` gives empty bytes when the client closed. It gives chunks: where a request ends is for your protocol to decide, and a buffer that grows on each chunk (`buffer + chunk`) is quadratic on a big request, so cap the size of a request and cut it as the bytes arrive. If `idle_ms` passes, the socket is closed.
- `send` writes all of `bytes`, in the pieces that `TCP.send_bytes` takes, so it has no size limit. If the client does not take a piece in `send_ms`, the socket is closed. `close` closes the socket of the client; the handler does not need it, since returning closes it.
- `Conn` and `Server` have more fields, which are private: a user cannot read them or make a value of the types they hold. Use the functions above, and do not call `TCP` on a client.
- Not released: in the next version `send` is queued. It puts the bytes in an outbox of the client, returns at once, works from any task that has the `Conn` (a state task can answer a client with the `Conn` it got in a message), and fails when the client is gone or was dropped for not reading. `close` then closes after what is queued was written, and `send_ms` goes away.
- A crash of a handler prints its diagnostic and stack on the stderr of the VM, closes the socket, and the server goes on. A handler that wants to log its own errors handles the `Result`s it gets.
- A handler is a function, or a block that captures what it needs. A server with one task that owns the state passes it a channel. That channel holds a number of messages, not bytes, so bound what a client can put in it: cap the size of a request that the handler reads, and do not read the next one while the channel is full (`send` with a timeout of 0 tells it).

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
- The supervisor owns the sockets, not the client tasks, so that it can close one when its handler crashed or was cancelled (a crash does not run the handler's last lines). It learns of the end of every task with `Task.monitor`. The task closes the socket itself when the handler returns, so the client sees the end at once. A close is idempotent, so the second one does nothing. A lost notice would keep a socket until the server stops, and a full channel drops notices, so the channel holds 1,048,576, which is more than the open files of a process, and the supervisor empties it between accepts. It costs no memory up front (an idle server is the same size with 1,024 or 1,048,576). The next versions size it from the limit of connections.
- `Task.spawn_owning` would give the socket to the task, but it cannot also pass a shared channel ([agentica#1341](https://github.com/agentica-lang/agentica/issues/1341)), which a handler that talks to a state task needs.
- A receive that times out closes the socket, and there is no wait-forever form ([agentica#1342](https://github.com/agentica-lang/agentica/issues/1342)). So `idle_ms` is a value of the `Config`, one year by default.
- A timeout of an accept adds no delay to a client that comes next. An accept that fails at once (no free file descriptor) waits the rest of the 100 ms before the next try, so it cannot spin. A closed listener, which fails at once for ever, ends the server with an error.

## Planned

Tracked in [#71](https://github.com/agentica-lang/packages/issues/71): a writer side (an outbox for each client with a limit in bytes, so a client that does not read is dropped and nobody waits), pushes to a client from another task, a limit of connections, counters (open, accepted, dropped), a graceful stop, and stopping when the task of the user dies.

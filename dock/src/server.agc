## The supervisor: one task that listens, accepts, starts a task per client and closes what ended.

import Connection from "connection"
import {Config, Conn, Server} from "types"

# How long one accept waits. It is also the longest a stop, or the close of the socket of a crashed handler, can
# take, and the pause after an accept that fails at once (EMFILE), so that error cannot spin.
ACCEPT_MS = 100
# How long `start` waits for the supervisor to listen, and `stop` for it to finish.
START_WAIT_MS = 5000
STOP_WAIT_MS = 5000
# Each handler task ends once and makes one notice; the channel holds as many as the largest limit of sockets
# of a process, so a notice is never dropped (a full channel drops them, see Task.monitor).
DOWNS_CAPACITY = 1_048_576

struct Boot
  config: Config
  handler: Fn[Conn, Void]
  ready: Channel[Result[Int]]
  stop_signal: Channel[Bool]
end

struct Live
  socket: Socket
  task: Task[Void]
end

## Listens and returns once the port is open; `handler` runs in a task of its own for each client.
export def start(config: Config, handler: Fn[Conn, Void]) -> Result[Server]
  ready: Channel[Result[Int]] = Channel.new(1)
  stop_signal: Channel[Bool] = Channel.new(1)
  task = Task.spawn(&supervise, Boot(config: config, handler: handler, ready: ready, stop_signal: stop_signal))
  answer = try ready.recv(START_WAIT_MS)
  port = try answer
  return ok(Server(port: port, stop_signal: stop_signal, task: task))
end

## Stops accepting, closes every client and frees the port.
export def stop(server: Server) -> Result[Void]
  server.stop_signal.close
  case Task.await(server.task, STOP_WAIT_MS)
    Await.Done(result) -> return result
    Await.TimedOut ->
      Task.cancel(server.task)
      return error("dock: the server did not stop in #{STOP_WAIT_MS} ms")
  end
end

## Waits until the server ends.
export def wait(server: Server) -> Result[Void]
  return Task.await(server.task)
end

# The listener belongs to this task, so it closes whatever way the task ends.
def supervise(boot: Boot) -> Result[Void]
  case TCP.listen(boot.config.host, boot.config.port)
    error(message) ->
      _ = boot.ready.send(error(message), 0)
      return error(message)
    ok(listener) ->
      _ = boot.ready.send(ok(TCP.local_port(listener)), 0)
      accept_loop(listener, boot)
      TCP.close_listener(listener)
      return ok()
  end
end

def accept_loop(listener: Listener, boot: Boot) -> Void
  downs: Channel[Int] = Channel.new(DOWNS_CAPACITY)
  live: Map[Int, Live] = {}
  next_id = 1
  while not boot.stop_signal.closed?
    started = Time.now_ms
    case TCP.accept(listener, ACCEPT_MS)
      ok(socket) ->
        live = live.put(next_id, spawn_client(socket, next_id, boot, downs))
        next_id += 1
      error(_) -> pause(started)
    end

    live = reap(live, downs)
  end

  for entry in live.values
    Task.cancel(entry.task)
    TCP.close(entry.socket)
  end
end

def spawn_client(socket: Socket, id: Int, boot: Boot, downs: Channel[Int]) -> Live
  conn = Conn(
    id: id,
    socket: socket,
    peer: TCP.remote_address(socket),
    idle_ms: boot.config.idle_ms,
    send_ms: boot.config.send_ms,
  )

  task = Task.spawn(&Connection.run, Connection.Link(conn: conn, handler: boot.handler))
  Task.monitor(task, downs) do |_down| id end
  return Live(socket: socket, task: task)
end

# A timeout already waited ACCEPT_MS; an error that came sooner waits the rest.
def pause(started: Int) -> Void
  left = ACCEPT_MS - (Time.now_ms - started)
  if left > 0
    Task.sleep(left)
  end
end

# The socket is closed whether the task returned (it closed it already: a second close does nothing), crashed or was
# cancelled.
def reap(live: Map[Int, Live], downs: Channel[Int]) -> Map[Int, Live]
  left = live
  while true
    case downs.recv(0)
      error(_) -> return left
      ok(id) ->
        case left.get(id)
          none -> nil
          some(entry) -> TCP.close(entry.socket)
        end

        left = left.delete(id)
    end
  end

  return left
end

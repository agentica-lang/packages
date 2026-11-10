import Dock from "../dock"

# Real sockets on 127.0.0.1 and a port picked by the system: the handlers run in the tasks of the server.

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

# "boom" crashes the handler, which is what a bug of the user looks like to the server.
def echo_or_crash(conn: Dock.Conn) -> Void
  case Dock.recv(conn, 4096)
    error(_) -> return
    ok(chunk) ->
      if chunk.empty?
        return
      end

      if chunk == "boom".bytes
        puts("crashing on purpose".to_i!)
      end

      _ = Dock.send(conn, chunk)
  end
end

# Ignores its socket for good: only a cancel from the server can end it.
def hold(_conn: Dock.Conn) -> Void
  while true
    Task.sleep(20)
  end
end

def serve(handler: Fn[Dock.Conn, Void]) -> Result[Dock.Server]
  return Dock.start(Dock.Config(port: 0), handler)
end

# Sends `text` and reads until all of it came back, or the server closed.
def exchange(port: Int, text: String) -> Result[String]
  socket = try TCP.connect("127.0.0.1", port, 5000)
  try TCP.send(socket, text, 5000)
  got = "".bytes
  while got.size < text.bytes.size
    chunk = try TCP.recv_bytes(socket, 4096, 5000)
    if chunk.empty?
      break
    end

    got = got + chunk
  end

  TCP.close(socket)
  return String.from_bytes(got)
end

# The open files of this process, so a socket the server forgot to close shows. `none` when the system has no /proc.
def open_files() -> Optional[Int]
  case Dir.list("/proc/self/fd")
    ok(names) -> return some(names.size)
    error(_) -> return none
  end
end

# The count must come back to `before`; the server closes a crashed client's socket at its next turn, so wait for it
# up to a deadline instead of sleeping a fixed time.
def settles_at(before: Optional[Int]) -> Result[Void]
  case before
    none -> return ok()
    some(count) ->
      deadline = Time.now_ms + 5000
      while open_files() != some(count) and Time.now_ms < deadline
        Task.sleep(20)
      end

      return Test.eq(open_files(), some(count))
  end
end

def test_clients_get_their_own_bytes_back() -> Result[Void]
  server = try serve(&echo)
  try Test.assert(server.port > 0, "the port is the real one")
  port = server.port
  results = Task.map((1..200).to_a, 50, 20000) do |n|
    text = "client #{n} says hello"
    got = try exchange(port, text)
    Test.eq(got, text)
  end

  try Test.eq(results.select do |r| not r.ok? end.size, 0)
  return Dock.stop(server)
end

def test_a_client_that_leaves_and_a_crashing_handler_leak_nothing() -> Result[Void]
  server = try serve(&echo_or_crash)
  before = open_files()
  for _ in 1..300
    socket = try TCP.connect("127.0.0.1", server.port, 5000)
    TCP.close(socket)
  end

  try Test.eq(exchange(server.port, "boom"), ok(""))
  try Test.eq(exchange(server.port, "still here"), ok("still here"))
  try settles_at(before)
  return Dock.stop(server)
end

def test_stop_ends_a_handler_that_never_returns_and_frees_the_port() -> Result[Void]
  server = try serve(&hold)
  port = server.port
  client = try TCP.connect("127.0.0.1", port, 5000)
  try Dock.stop(server)
  # The server closed its side: the client reads the end, or a reset.
  case TCP.recv_bytes(client, 1, 5000)
    ok(bytes) -> try Test.assert(bytes.empty?, "the stream ended")
    error(_) -> nil
  end

  TCP.close(client)
  try Test.error?(TCP.connect("127.0.0.1", port, 1000))
  rebound = try TCP.listen("127.0.0.1", port)
  TCP.close_listener(rebound)
  return ok()
end

def test_a_port_in_use_is_an_error() -> Result[Void]
  taken = try TCP.listen("127.0.0.1", 0)
  result = Dock.start(Dock.Config(port: TCP.local_port(taken)), &echo)
  TCP.close_listener(taken)
  return Test.error?(result)
end

import Dock from "../dock"
import Outbox from "../src/outbox"
import Serving from "../src/server"

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

# "boom" crashes the handler after a pause, which is what a bug of the user looks like to the server: the socket is
# closed by the supervisor, on a later turn than the one that started the handler.
def echo_or_crash(conn: Dock.Conn) -> Void
  case Dock.recv(conn, 4096)
    error(_) -> return
    ok(chunk) ->
      if chunk.empty?
        return
      end

      if chunk == "boom".bytes
        Task.sleep(100)
        puts("crashing on purpose".to_i!)
      end

      _ = Dock.send(conn, chunk)
  end
end

# Queues 20 MiB for a client that never reads, so its writer is stuck, then ignores its socket for good: only a
# cancel from the server can end it.
def hold(conn: Dock.Conn) -> Void
  _ = Dock.send(conn, mib(20))
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
  # The first byte shows the handler runs and its writer is sending; the client reads no more, so 20 MiB stay queued.
  try Test.eq(TCP.recv_bytes(client, 1, 5000), ok("x".bytes))
  try Dock.stop(server)
  TCP.close(client)
  try Test.error?(TCP.connect("127.0.0.1", port, 1000))
  # A second stop and a wait after it give the same result, and the port can serve again.
  try Test.eq(Dock.stop(server), ok())
  try Test.eq(Dock.wait(server), ok())
  again = try Dock.start(Dock.Config(port: port), &echo)
  try Test.eq(exchange(port, "back"), ok("back"))
  return Dock.stop(again)
end

def mib(count: Int) -> Bytes
  piece = ("x" * 1_048_576).bytes
  return Bytes.concat((1..count).to_a.map do |_| piece end)
end

# One server with a short idle time and a small outbox. Each client asks for a case by its first word; the handler
# reports what happened on `report`, which the test reads.
def probe(conn: Dock.Conn, report: Channel[String]) -> Void
  case Dock.recv(conn, 16)
    error(_) -> return
    ok(command) ->
      if command == "idle".bytes
        # Nothing more comes: this receive times out.
        _ = report.send("idle #{Dock.recv(conn, 16).ok?}", 5000)
      elsif command == "flood".bytes
        _ = report.send(flood(conn), 5000)
      else
        _ = Dock.send(conn, "pong".bytes)
      end
  end
end

# The client never reads. The writer fills the socket buffers, the queue passes the cap, and the send that does is
# refused. The messages are 1 MiB, so the 1,564 that the channel holds for this cap are never what stops it: the
# bytes are. The loop is bounded so a missing drop fails instead of hanging.
def flood(conn: Dock.Conn) -> String
  piece = mib(1)
  for n in 1..200
    case Dock.send(conn, piece)
      error(_) -> return "dropped #{n < 100} #{Dock.send(conn, piece).ok?}"
      ok(_) -> nil
    end
  end

  return "never dropped"
end

def test_idle_timeout_and_a_flooded_client_dropped_at_the_cap() -> Result[Void]
  report: Channel[String] = Channel.new(8)
  config = Dock.Config(port: 0, idle_ms: 500, max_outbox_bytes: 100_000)
  server = try Dock.start(config) do |conn| probe(conn, report) end
  idler = try start_client(server.port, "idle")
  try Test.eq(report.recv(5000), ok("idle false"))
  flooder = try start_client(server.port, "flood")
  try Test.eq(report.recv(10000), ok("dropped true false"))
  # Others are served, and a stop does not wait for the stalled client.
  try Test.eq(exchange(server.port, "ping"), ok("pong"))
  started = Time.now_ms
  try Dock.stop(server)
  try Test.assert(Time.now_ms - started < 5000, "stop waited for the full outbox")
  TCP.close(idler)
  TCP.close(flooder)
  return ok()
end

def start_client(port: Int, word: String) -> Result[Socket]
  socket = try TCP.connect("127.0.0.1", port, 5000)
  try TCP.send(socket, word, 5000)
  return ok(socket)
end

# Reads until the server closes.
def read_all(socket: Socket) -> Result[Bytes]
  got = "".bytes
  while true
    chunk = try TCP.recv_bytes(socket, 65_536, 10_000)
    if chunk.empty?
      return ok(got)
    end

    got = got + chunk
  end

  return ok(got)
end

# 10 tasks send 100 messages each to a connection they got over a channel; `close` then ends it after the last.
def test_send_from_other_tasks_keeps_each_message_whole_and_in_order() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  server = try Dock.start(Dock.Config(port: 0)) do |conn| keep(conn, conns) end
  client = try start_client(server.port, "go")
  conn = try conns.recv(5000)
  results = Task.map((1..10).to_a, 10, 20000) do |task|
    for n in 1..100
      try Dock.send(conn, "#{task}:#{n};".bytes)
    end

    ok(task)
  end

  try Test.eq(results.select do |r| not r.ok? end.size, 0)
  Dock.close(conn)
  got = String.from_bytes(try read_all(client)).unwrap!
  TCP.close(client)
  messages = got.split(";").select do |m| not m.empty? end
  try Test.eq(messages.size, 1000)
  for task in 1..10
    mine = messages.select do |m| m.start_with?("#{task}:") end
    try Test.eq(mine, (1..100).to_a.map do |n| "#{task}:#{n}" end)
  end

  try Test.eq(Dock.send(conn, "late".bytes).ok?, false)
  return Dock.stop(server)
end

# Hands the Conn to the test, then reads until the connection ends.
def keep(conn: Dock.Conn, conns: Channel[Dock.Conn]) -> Void
  _ = Dock.recv(conn, 16)
  _ = conns.send(conn, 5000)
  while Dock.recv(conn, 16).ok?
    nil
  end
end

def test_send_after_the_client_left_is_an_error() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  server = try Dock.start(Dock.Config(port: 0)) do |conn| keep(conn, conns) end
  client = try start_client(server.port, "go")
  conn = try conns.recv(5000)
  TCP.close(client)
  deadline = Time.now_ms + 5000
  while Dock.send(conn, "x".bytes).ok? and Time.now_ms < deadline
    Task.sleep(20)
  end

  try Test.eq(Dock.send(conn, "x".bytes).ok?, false)
  return Dock.stop(server)
end

def test_one_message_over_the_cap_arrives_whole_for_a_slow_reader() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0)) do |conn| big(conn) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  Task.sleep(300)
  got = try read_all(client)
  TCP.close(client)
  try Test.eq(got.size, 20 * 1_048_576)
  return Dock.stop(server)
end

def big(conn: Dock.Conn) -> Void
  _ = Dock.send(conn, mib(20))
  Dock.close(conn)
  _ = Dock.recv(conn, 16)
end

def test_the_cap_and_the_config_are_checked() -> Result[Void]
  # With nothing pending a message is never refused; with a backlog it is when the total passes the cap.
  try Test.eq(Outbox.refused?(1_000_064, 1_000_064, 100), false)
  try Test.eq(Outbox.refused?(100, 40, 100), false)
  try Test.eq(Outbox.refused?(101, 40, 100), true)
  try Test.error?(Dock.start(Dock.Config(port: 0, max_outbox_bytes: 0), &echo))
  return Test.error?(Dock.start(Dock.Config(port: 0, max_outbox_bytes: Outbox.MAX_CAP + 1), &echo))
end

# The loop of the supervisor on a listener that the test closes under it.
def test_a_closed_listener_ends_the_loop_with_an_error() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  stop_signal: Channel[Bool] = Channel.new(1)
  loop = Task.spawn do Serving.accept_loop(listener, Dock.Config(port: 0), &hold, stop_signal) end

  TCP.close_listener(listener)
  case Task.await(loop, 5000)
    Await.Done(result) -> return Test.error?(result)
    Await.TimedOut ->
      Task.cancel(loop)
      return error("the loop did not end")
  end
end

def test_a_port_in_use_is_an_error() -> Result[Void]
  taken = try TCP.listen("127.0.0.1", 0)
  result = Dock.start(Dock.Config(port: TCP.local_port(taken)), &echo)
  TCP.close_listener(taken)
  return Test.error?(result)
end

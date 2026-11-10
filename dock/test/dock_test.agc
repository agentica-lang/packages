import Dock from "../dock"
import Outbox from "../src/outbox"
import Serving from "../src/server"
import Counters from "../src/stats"
import Types from "../src/types"

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
  try Test.eq(Dock.stats(server).dropped, 1)
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
  # The close is in the queue: a send after it fails now, not only once the client read the end.
  try Test.eq(Dock.send(conn, "late".bytes).ok?, false)
  got = String.from_bytes(try read_all(client)).unwrap!
  TCP.close(client)
  messages = got.split(";").select do |m| not m.empty? end
  try Test.eq(messages.size, 1000)
  for task in 1..10
    mine = messages.select do |m| m.start_with?("#{task}:") end
    try Test.eq(mine, (1..100).to_a.map do |n| "#{task}:#{n}" end)
  end

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

# With cap 100,000: "b" gets a reply of 1 MiB and then a short one, as a client that reads normally must; "s" gets
# 1 MiB in 1 KiB messages, 1,100,000 charged against the cap, so the writer must subtract what it wrote.
def reply(conn: Dock.Conn) -> Void
  case Dock.recv(conn, 1)
    error(_) -> return
    ok(command) ->
      if command == "b".bytes
        _ = Dock.send(conn, mib(1))
        _ = Dock.send(conn, "OK\r\n".bytes)
      else
        piece = ("x" * 1024).bytes
        for n in 1..1024
          _ = Dock.send(conn, piece)
          # Paced, so a client that reads is never more than a few KiB behind.
          if n % 8 == 0
            Task.sleep(1)
          end
        end
      end

      Dock.close(conn)
      _ = Dock.recv(conn, 16)
  end
end

def test_a_client_that_reads_is_never_dropped_for_the_size_of_what_it_got() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0, max_outbox_bytes: 100_000)) do |conn| reply(conn) end
  big = try start_client(server.port, "b")
  got = try read_all(big)
  try Test.eq(got.size, 1_048_576 + 4)
  TCP.close(big)
  small = try start_client(server.port, "s")
  got_small = try read_all(small)
  try Test.eq(got_small.size, 1_048_576)
  TCP.close(small)
  return Dock.stop(server)
end

def test_the_cap_and_the_config_are_checked() -> Result[Void]
  cap = 100
  # The charge is capped, and a message is refused when the charges waiting before it pass the cap.
  try Test.eq(Outbox.charge(10, cap), 74)
  try Test.eq(Outbox.charge(1_000_000, cap), cap)
  try Test.eq(Outbox.refused?(100, 100, cap), false)
  try Test.eq(Outbox.refused?(200, 100, cap), false)
  try Test.eq(Outbox.refused?(201, 100, cap), true)
  try Test.error?(Dock.start(Dock.Config(port: 0, max_outbox_bytes: Outbox.MIN_CAP - 1), &echo))
  try Test.error?(Dock.start(Dock.Config(port: 0, max_outbox_bytes: Outbox.MAX_CAP + 1), &echo))
  try Test.error?(Dock.start(Dock.Config(port: 0, max_connections: 0), &echo))
  try Test.error?(Dock.start(Dock.Config(port: 0, max_connections: 1_048_577), &echo))
  try Test.error?(Dock.start(Dock.Config(port: 0, grace_ms: -1), &echo))
  try Test.error?(Dock.start(Dock.Config(port: 0, grace_ms: 9_223_372_036_854_775_000), &echo))
  # A drop that another task already counted is not counted again.
  listener = try TCP.listen("127.0.0.1", 0)
  socket = try TCP.connect("127.0.0.1", TCP.local_port(listener), 5000)
  stats: ATS[Int, Int] = ATS.new()
  outbox = Outbox.build(cap, stats)
  outbox.pending.put(Outbox.DROPPED_KEY, 1)
  big = ("x" * 500).bytes
  try Outbox.push(outbox, socket, big)
  try Outbox.push(outbox, socket, big)
  try Test.error?(Outbox.push(outbox, socket, big))
  try Test.eq(stats.add(Counters.DROPPED, 0), 0)
  TCP.close(socket)
  TCP.close_listener(listener)
  # The largest cap needs the largest channel the VM allows.
  server = try Dock.start(Dock.Config(port: 0, max_outbox_bytes: Outbox.MAX_CAP), &echo)
  try Test.eq(exchange(server.port, "hi"), ok("hi"))
  return Dock.stop(server)
end

# The loop of the supervisor on a listener that the test closes under it.
def test_a_closed_listener_ends_the_loop_with_an_error() -> Result[Void]
  listener = try TCP.listen("127.0.0.1", 0)
  stop_signal: Channel[Bool] = Channel.new(1)
  watched: Channel[String] = Channel.new(1)
  stats: ATS[Int, Int] = ATS.new()
  boot = Serving.Boot(
    config: Dock.Config(port: 0),
    handler: &hold,
    ready: Channel.new(1),
    stop_signal: stop_signal,
    stats: stats,
    watched: watched,
    hook_ends: Channel.new(1),
  )

  loop = Task.spawn do Serving.accept_loop(listener, boot) end

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

# Waits until `done` is true of the counters, up to a deadline.
def await_stats(server: Dock.Server, done: Fn[Dock.Stats, Bool]) -> Result[Void]
  deadline = Time.now_ms + 10_000
  while not done.call(Dock.stats(server)) and Time.now_ms < deadline
    Task.sleep(20)
  end

  return Test.assert(done.call(Dock.stats(server)), "the counters did not get there: #{Dock.stats(server)}")
end

# The handler of the limit and watch tests: it reads until the client leaves, or crashes at "boom".
def sit(conn: Dock.Conn) -> Void
  while true
    case Dock.recv(conn, 16)
      error(_) -> return
      ok(chunk) ->
        if chunk.empty?
          return
        end

        if chunk == "boom".bytes
          puts("crashing on purpose".to_i!)
        end
    end
  end
end

# A config whose `on_close` sends the id of each connection that ended to `ids`.
def noting(config: Dock.Config, ids: Channel[Int]) -> Dock.Config
  return Dock.on_close(config) do |conn| _ = ids.send(conn.id, 5000) end
end

def test_a_connection_over_the_limit_is_closed_at_once_and_a_freed_slot_is_reused() -> Result[Void]
  config = Dock.Config(port: 0, max_connections: 3)
  server = try Dock.start(config, &sit)
  clients: List[Socket] = []
  for _ in 1..3
    clients = clients.push(try TCP.connect("127.0.0.1", server.port, 5000))
  end

  try await_stats(server) do |s| s.open == 3 end
  # The fourth is accepted and closed by the server: it reads the end, it does not wait.
  over = try TCP.connect("127.0.0.1", server.port, 5000)
  try Test.eq(TCP.recv_bytes(over, 1, 5000), ok("".bytes))
  TCP.close(over)
  try Test.eq(Dock.stats(server).refused, 1)
  try Test.eq(Dock.stats(server).accepted, 3)
  TCP.close(clients[0])
  try await_stats(server) do |s| s.open == 2 end
  again = try start_client(server.port, "hi")
  try await_stats(server) do |s| s.accepted == 4 end
  TCP.close(again)
  for client in clients
    TCP.close(client)
  end

  return Dock.stop(server)
end

# 100 handlers crash in the same moment, so 100 notices wait for one turn of the supervisor: each socket must be
# closed, each counted, each given to on_close, and the descriptors come back.
def test_many_connections_ending_at_once_are_all_closed_and_counted() -> Result[Void]
  ids: Channel[Int] = Channel.new(200)
  config = noting(Dock.Config(port: 0, max_connections: 100), ids)
  server = try Dock.start(config, &sit)
  before = open_files()
  clients: List[Socket] = []
  for _ in 1..100
    clients = clients.push(try TCP.connect("127.0.0.1", server.port, 5000))
  end

  try await_stats(server) do |s| s.open == 100 end
  for client in clients
    try TCP.send(client, "boom", 5000)
  end

  for client in clients
    try Test.eq(TCP.recv_bytes(client, 1, 10_000), ok("".bytes))
    TCP.close(client)
  end

  try await_stats(server) do |s| s.open == 0 and s.crashed == 100 end
  seen: List[Int] = []
  for _ in 1..100
    seen = seen.push(try ids.recv(10_000))
  end

  try Test.eq(seen.sort, (1..100).to_a)
  try settles_at(before)
  return Dock.stop(server)
end

def test_on_close_fires_for_a_return_a_crash_and_the_stop() -> Result[Void]
  ids: Channel[Int] = Channel.new(8)
  server = try Dock.start(noting(Dock.Config(port: 0), ids), &echo_or_crash)
  try Test.eq(exchange(server.port, "hi"), ok("hi"))
  # The client may see the end as a reset, so the answer is not checked, only that the handler crashed.
  _ = exchange(server.port, "boom")
  staying = try TCP.connect("127.0.0.1", server.port, 5000)
  try await_stats(server) do |s| s.accepted == 3 end
  try Dock.stop(server)
  TCP.close(staying)
  seen: List[Int] = []
  for _ in 1..3
    seen = seen.push(try ids.recv(5000))
  end

  try Test.eq(seen.sort, [1, 2, 3])
  return ok()
end

def test_a_watched_task_that_crashes_stops_the_server_and_wait_says_why() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0), &sit)
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  central = Task.spawn do
    Task.sleep(200)
    puts("central task".to_i!)
  end

  Dock.watch(server, central)
  waiter = Task.spawn do Dock.wait(server) end
  case Task.await(waiter, 10_000)
    Await.TimedOut -> return error("wait did not return after the watched task crashed")
    Await.Done(result) -> try Test.assert(result.message.include?("the watched task crashed"), result.message)
  end

  try Test.eq(TCP.recv_bytes(client, 1, 5000), ok("".bytes))
  TCP.close(client)
  return Test.error?(TCP.connect("127.0.0.1", server.port, 1000))
end

# Sends 20 MiB and keeps reading, so the handler ends when its socket is closed.
def deliver(conn: Dock.Conn) -> Void
  _ = Dock.send(conn, mib(20))
  while Dock.recv(conn, 16).ok?
    nil
  end
end

def test_stop_with_a_grace_lets_a_slow_client_get_what_was_queued() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0, grace_ms: 10_000), &deliver)
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  try Test.eq(TCP.recv_bytes(client, 1, 5000), ok("x".bytes))
  started = Time.now_ms
  stopper = Task.spawn do Dock.stop(server) end
  # The client reads only after the stop began (it takes up to 100 ms to see it): the queue is what survives it.
  Task.sleep(300)
  got = try read_all(client)
  TCP.close(client)
  try Test.eq(got.size, 20 * 1_048_576 - 1)
  case Task.await(stopper, 15_000)
    Await.TimedOut -> return error("stop did not return")
    Await.Done(result) -> try result
  end

  return Test.assert(Time.now_ms - started < 8000, "stop waited the whole grace for a client that was done")
end

def test_stop_closes_a_client_that_never_reads_when_the_grace_ends() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0, grace_ms: 500), &hold)
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  try Test.eq(TCP.recv_bytes(client, 1, 5000), ok("x".bytes))
  started = Time.now_ms
  try Dock.stop(server)
  try Test.assert(Time.now_ms - started < 5000, "stop took more than the grace")
  TCP.close(client)
  return ok()
end

def running_callbacks(server: Dock.Server) -> Int
  case server.inside
    Types.ServerParts.Parts(_, _, table, _, _) -> return table.add(Counters.HOOKS, 0)
  end
end

def test_a_callback_that_crashes_does_not_crash_the_stop() -> Result[Void]
  config = Dock.on_close(Dock.Config(port: 0)) do |_conn| puts("callback".to_i!) end
  server = try Dock.start(config, &echo_or_crash)
  try Test.eq(exchange(server.port, "hi"), ok("hi"))
  staying = try TCP.connect("127.0.0.1", server.port, 5000)
  try await_stats(server) do |s| s.accepted == 2 end
  started = Time.now_ms
  try Test.eq(Dock.stop(server), ok())
  try Test.assert(Time.now_ms - started < 5000, "the stop took too long")
  # The count of running callbacks went down for the ones that crashed (it is what the stop waits on).
  try Test.eq(running_callbacks(server), 0)
  TCP.close(staying)
  return Test.eq(Dock.wait(server), ok())
end

# 100 callbacks that sleep: the accept loop must not pay for them, so a new client is served at once.
def test_slow_callbacks_never_hold_the_accept_loop() -> Result[Void]
  done: Channel[Int] = Channel.new(200)
  config = Dock.on_close(Dock.Config(port: 0)) do |conn|
    Task.sleep(1500)
    _ = done.send(conn.id, 5000)
  end

  server = try Dock.start(config, &echo)
  port = server.port
  results = Task.map((1..100).to_a, 50, 20000) do |n|
    got = try exchange(port, "client #{n}")
    Test.eq(got, "client #{n}")
  end

  try Test.eq(results.select do |r| not r.ok? end.size, 0)
  try await_stats(server) do |s| s.open == 0 end
  started = Time.now_ms
  try Test.eq(exchange(port, "fresh"), ok("fresh"))
  try Test.assert(Time.now_ms - started < 1000, "a new client waited for the callbacks")
  for _ in 1..101
    _ = try done.recv(10_000)
  end

  return Dock.stop(server)
end

# At the limit, a slot that a handler is freeing is waited for a moment, so a client that comes right after another
# left is not refused.
def test_one_slot_serves_sequential_clients() -> Result[Void]
  server = try Dock.start(Dock.Config(port: 0, max_connections: 1), &echo)
  for n in 1..300
    try Test.eq(exchange(server.port, "n#{n}"), ok("n#{n}"))
  end

  try Test.eq(Dock.stats(server).refused, 0)
  return Dock.stop(server)
end

# The store-task pattern: the handler gives the Conn away and returns at once. Whoever got it owns the connection.
def pass_on(conn: Dock.Conn, conns: Channel[Dock.Conn]) -> Void
  Dock.hand_over(conn)
  _ = conns.send(conn, 5000)
end

# The handler has returned for a while when the reply is queued, and the client still gets it.
def test_a_handed_over_connection_stays_open_for_a_reply_after_the_handler_returned() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  ids: Channel[Int] = Channel.new(8)
  config = noting(Dock.Config(port: 0), ids)
  server = try Dock.start(config) do |conn| pass_on(conn, conns) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  conn = try conns.recv(5000)
  Task.sleep(300)
  try Test.eq(Dock.stats(server).open, 1)
  try Dock.send(conn, "late reply".bytes)
  try Test.eq(TCP.recv_bytes(client, 64, 5000), ok("late reply".bytes))
  try Test.error?(ids.recv(100))
  Dock.close(conn)
  try Test.eq(read_all(client), ok("".bytes))
  try Test.eq(ids.recv(5000), ok(1))
  TCP.close(client)
  try await_stats(server) do |s| s.open == 0 end
  try Test.error?(ids.recv(300))
  return Dock.stop(server)
end

# After the hand-over the client leaves: a task that reads sees it, and the connection ends once.
def test_the_end_of_a_client_seen_by_a_reader_closes_a_handed_over_connection_once() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  ids: Channel[Int] = Channel.new(8)
  config = noting(Dock.Config(port: 0), ids)
  server = try Dock.start(config) do |conn| pass_on(conn, conns) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  conn = try conns.recv(5000)
  reader = Task.spawn do Dock.recv(conn, 16) end
  Task.sleep(200)
  try Test.eq(Dock.stats(server).open, 1)
  TCP.close(client)
  try Test.eq(ids.recv(5000), ok(1))
  try await_stats(server) do |s| s.open == 0 end
  try Test.eq(Dock.stats(server).accepted, 1)
  try Test.error?(ids.recv(300))
  try Test.error?(Dock.send(conn, "x".bytes))
  Task.cancel(reader)
  return Dock.stop(server)
end

def test_a_handed_over_client_that_does_not_read_is_dropped_at_the_cap() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  ids: Channel[Int] = Channel.new(8)
  config = noting(Dock.Config(port: 0, max_outbox_bytes: 100_000), ids)
  server = try Dock.start(config) do |conn| pass_on(conn, conns) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  conn = try conns.recv(5000)
  try Test.eq(flood(conn), "dropped true false")
  try Test.eq(ids.recv(5000), ok(1))
  try await_stats(server) do |s| s.open == 0 and s.dropped == 1 end
  try Test.error?(ids.recv(300))
  TCP.close(client)
  return Dock.stop(server)
end

def test_stop_ends_a_handed_over_connection_nobody_closes() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  ids: Channel[Int] = Channel.new(8)
  config = noting(Dock.Config(port: 0), ids)
  server = try Dock.start(config) do |conn| pass_on(conn, conns) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  _ = try conns.recv(5000)
  Task.sleep(200)
  started = Time.now_ms
  try Dock.stop(server)
  try Test.assert(Time.now_ms - started < 5000, "stop waited for a handed over connection")
  try Test.eq(TCP.recv_bytes(client, 1, 5000), ok("".bytes))
  TCP.close(client)
  try Test.eq(ids.recv(5000), ok(1))
  try Test.eq(Dock.stats(server).open, 0)
  return Test.error?(ids.recv(300))
end

def test_a_bad_max_bytes_does_not_close_a_handed_over_connection() -> Result[Void]
  conns: Channel[Dock.Conn] = Channel.new(1)
  server = try Dock.start(Dock.Config(port: 0)) do |conn| pass_on(conn, conns) end
  client = try TCP.connect("127.0.0.1", server.port, 5000)
  conn = try conns.recv(5000)
  try Test.error?(Dock.recv(conn, 0))
  try Test.error?(Dock.recv(conn, 2_000_000))
  Task.sleep(200)
  try Test.eq(Dock.stats(server).open, 1)
  try Dock.send(conn, "still open".bytes)
  try Test.eq(TCP.recv_bytes(client, 64, 5000), ok("still open".bytes))
  TCP.close(client)
  return Dock.stop(server)
end

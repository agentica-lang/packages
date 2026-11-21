import HttpClient from "../http_client"

private

ROUNDS = 300
PEER_START_MS = 60_000
BUFFER_WAIT_MS = 2_000

# The server is a process of its own, so that its tasks are not counted with the client's.
def server() -> Result[Process]
  Process.spawn(System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica"), ["test/specs/fixtures/server.agc"])
end

# The idle watcher of the connection must be gone before each request reads its response: a watcher still reading
# would take the first byte of it. One connection, many requests in a row, and none may fail. Once the client is
# closed, none of its tasks is left: the count of tasks is the one from before the client.
def test_requests_in_a_row_on_one_connection_all_get_their_response_and_close_leaves_no_task() -> Result[Void]
  before = Task.pending_count()
  peer = try server()
  port = (try Process.read_line(peer, PEER_START_MS)).split(" ").last
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{port}", pool_size: 1, max_retries: 0)
  failures: List[String] = []
  for _ in 1..ROUNDS
    case HttpClient.get(client, "/hello")
      ok(_) -> nil
      error(e) -> failures = failures.push(e.message)
    end
  end

  HttpClient.close(client)
  left = Task.pending_count()
  Process.close(peer)
  try Test.eq(failures.take(3), [])
  Test.eq(left, before)
end

# A reader that stops reading its events without closing them leaves a relay task that waits for the reader, and a
# pump task that waits for the relay. `close` ends both, though `read_timeout_ms` is far: nothing of the client is
# left, and the events end with `http_client.closed` after the one that waited.
def test_close_ends_the_tasks_of_a_stream_whose_reader_is_gone() -> Result[Void]
  before = Task.pending_count()
  agentica = System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica")
  peer = try Process.spawn(agentica, ["test/specs/fixtures/raw_peer.agc", "repeat 20 500 data:_x\\n\\n"])
  port = (try Process.read_line(peer, PEER_START_MS)).split(" ").last
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{port}", read_timeout_ms: 60_000, max_retries: 0)
  events = try HttpClient.get_events(client, "/events")
  first = events.recv(PEER_START_MS)
  deadline = Time.monotonic_ms() + BUFFER_WAIT_MS
  while events.empty? and Time.monotonic_ms() < deadline
    Task.sleep(5)
  end

  began = Time.monotonic_ms()
  HttpClient.close(client, 0)
  closing_ms = Time.monotonic_ms() - began
  left = Task.pending_count()
  Process.close(peer)
  waited = events.recv(0)
  last = events.recv(0)
  try Test.eq(first.ok?, true)
  try Test.eq(waited.unwrap!.ok?, true)
  try Test.eq(failed_kind(last.unwrap!), "http_client.closed")
  try Test.eq(closing_ms < 2_000, true)
  Test.eq(left, before)
end

# A stream holds a pump task that may be waiting in a read of its socket. `close` ends it, and a `cancel` after that
# finds nothing to interrupt: it returns at once, a second one does the same, and nothing of the client is left.
def test_cancel_after_close_does_nothing() -> Result[Void]
  before = Task.pending_count()
  agentica = System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica")
  peer = try Process.spawn(agentica, ["test/specs/fixtures/raw_peer.agc", "repeat 20 500 data:_x\\n\\n"])
  port = (try Process.read_line(peer, PEER_START_MS)).split(" ").last
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{port}", read_timeout_ms: 60_000, max_retries: 0)
  stream = try HttpClient.stream(client, "GET", "/events")
  first = stream.body.recv(PEER_START_MS)
  HttpClient.close(client, 0)
  began = Time.monotonic_ms()
  HttpClient.cancel(stream)
  HttpClient.cancel(stream)
  cancelling_ms = Time.monotonic_ms() - began
  left = Task.pending_count()
  Process.close(peer)
  try Test.eq(first.ok?, true)
  try Test.eq(cancelling_ms < 1_000, true)
  Test.eq(left, before)
end

def failed_kind(item: Result[HttpClient.Event]) -> String
  case item
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

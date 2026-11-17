import HttpClient from "../http_client"

private

ROUNDS = 300
PEER_START_MS = 60_000
# Past the time a pool is kept after its last request with these settings (ASK_MS, 5 s, plus timeout_ms and idle_ms),
# and two sweeps of the manager after that.
IDLE_POOL_MS = 8_000
# Long enough for the events to fill the channel of a reader that took one.
STREAM_MS = 1_000

# The server is a process of its own, so that its tasks are not counted with the client's.
def server() -> Result[Process]
  Process.spawn(System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica"), ["specs/fixtures/server.agc"])
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

# A pool that no request wanted for a while is closed by the manager, which must go on serving: the next request to
# that origin gets a new pool, and the close is quick and leaves no task.
def test_a_request_after_its_pool_was_closed_for_idleness_gets_a_new_one() -> Result[Void]
  before = Task.pending_count()
  peer = try server()
  port = (try Process.read_line(peer, PEER_START_MS)).split(" ").last
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{port}", idle_ms: 1, timeout_ms: 100, max_retries: 0)
  first = HttpClient.get(client, "/hello")
  Task.sleep(IDLE_POOL_MS)
  again = HttpClient.get(client, "/hello")
  began = Time.monotonic_ms()
  HttpClient.close(client)
  closing_ms = Time.monotonic_ms() - began
  left = Task.pending_count()
  Process.close(peer)
  try Test.eq(first.ok?, true)
  try Test.eq(again.message, "")
  try Test.eq(again.unwrap!.status, 200)
  try Test.eq(closing_ms < 2_000, true)
  Test.eq(left, before)
end

# A reader that drops its events without closing them leaves a relay task that waits for room, and a pump task that
# waits for the relay. `close` ends both, though `read_timeout_ms` is far: nothing of the client is left.
def test_close_ends_the_tasks_of_a_stream_whose_reader_is_gone() -> Result[Void]
  before = Task.pending_count()
  agentica = System.env("HTTP_CLIENT_AGENTICA").unwrap_or("agentica")
  peer = try Process.spawn(agentica, ["specs/fixtures/raw_peer.agc", "repeat 20 500 data:_x\\n\\n"])
  port = (try Process.read_line(peer, PEER_START_MS)).split(" ").last
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{port}", read_timeout_ms: 60_000, max_retries: 0)
  events = try HttpClient.get_events(client, "/events")
  first = events.recv(PEER_START_MS)
  Task.sleep(STREAM_MS)
  began = Time.monotonic_ms()
  HttpClient.close(client, 0)
  closing_ms = Time.monotonic_ms() - began
  left = Task.pending_count()
  Process.close(peer)
  try Test.eq(first.ok?, true)
  try Test.eq(closing_ms < 2_000, true)
  Test.eq(left, before)
end

import HttpClient from "../http_client"

private

ROUNDS = 300
PEER_START_MS = 60_000

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

import HTTP from "std/http"
import HttpClient from "../http_client"

private

ROUNDS = 300

def hello(_request: HTTP.Request) -> Result[HTTP.Response]
  ok(HTTP.Response(status: 200, headers: [], body: "hello".bytes))
end

# The idle watcher of the connection must be gone before each request reads its response: a watcher still reading
# would take the first byte of it. One connection, many requests in a row, and none may fail.
def test_requests_in_a_row_on_one_connection_all_get_their_response() -> Result[Void]
  server = try HTTP.serve("127.0.0.1", 0, HTTP.app(&hello))
  client = try HttpClient.new(base_url: "http://127.0.0.1:#{HTTP.local_port(server)}", pool_size: 1, retries: 0)
  failures: List[String] = []
  for _ in 1..ROUNDS
    case HttpClient.get(client, "/")
      ok(_) -> nil
      error(e) -> failures = failures.push(e.message)
    end
  end

  HttpClient.close(client)
  HTTP.close_server(server)
  Test.eq(failures.take(3), [])
end

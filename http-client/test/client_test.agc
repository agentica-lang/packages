import HttpClient from "../http_client"

private

def kind(result: Result[HttpClient.Response]) -> String
  case result
    ok(_) -> "ok"
    error(e) -> e.kind
  end
end

def test_a_client_changed_with_with_is_checked_as_new_checks_it() -> Result[Void]
  client = try HttpClient.new()
  try Test.eq(kind(HttpClient.get(client.with(timeout_ms: 0), "http://127.0.0.1:9/")), "argument")
  try Test.eq(kind(HttpClient.get(client.with(read_timeout_ms: -1), "http://127.0.0.1:9/")), "argument")
  try Test.eq(kind(HttpClient.get(client.with(base_url: "ftp://example.com"), "/x")), "argument")
  HttpClient.close(client, 0)
  ok()
end
